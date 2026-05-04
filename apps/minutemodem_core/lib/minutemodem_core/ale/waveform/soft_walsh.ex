defmodule MinuteModemCore.ALE.Waveform.SoftWalsh do
  @moduledoc """
  Soft-decision Walsh-16 decoder with iterative DFE equalization.

  Two-pass architecture:
  1. First pass: Phase-search Walsh correlation on raw I/Q → quadbit decisions
  2. Reconstruct reference symbols from Walsh decisions → train DFE
  3. Second pass: DFE-equalized I/Q → Phase-search Walsh → final decisions

  The Walsh decoder (18 dB processing gain) produces reliable enough decisions
  to serve as training data for the DFE, which then removes ISI for a cleaner
  second decode pass. This "north/south" signalling between layers lets each
  component do what it's best at.
  """

  import Bitwise

  alias MinuteModemCore.DSP.PhyModem

  # Walsh-16 reference patterns (base, 16 symbols each)
  @walsh_16 %{
    0x0 => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    0x1 => [0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4],
    0x2 => [0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4],
    0x3 => [0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0],
    0x4 => [0, 0, 0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4],
    0x5 => [0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0],
    0x6 => [0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4, 0, 0],
    0x7 => [0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4],
    0x8 => [0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4],
    0x9 => [0, 4, 0, 4, 0, 4, 0, 4, 4, 0, 4, 0, 4, 0, 4, 0],
    0xA => [0, 0, 4, 4, 0, 0, 4, 4, 4, 4, 0, 0, 4, 4, 0, 0],
    0xB => [0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4],
    0xC => [0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, 0, 0, 0, 0],
    0xD => [0, 4, 0, 4, 4, 0, 4, 0, 4, 0, 4, 0, 0, 4, 0, 4],
    0xE => [0, 0, 4, 4, 4, 4, 0, 0, 4, 4, 0, 0, 0, 0, 4, 4],
    0xF => [0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0]
  }

  # Precompute Walsh-16 full (64 chips = 4 copies of base 16)
  @walsh_16_full Map.new(@walsh_16, fn {k, base} ->
    {k, List.flatten(List.duplicate(base, 4))}
  end)

  # Trial phase offsets: search full π range (BPSK ambiguity is π)
  @n_phases 64
  @phase_trials Enum.map(0..(@n_phases - 1), fn k -> k * :math.pi() / @n_phases end)

  @doc """
  Decode I/Q pairs — single pass, no DFE. Used for AWGN channels.
  """
  def decode_iq(iq_pairs, scrambler \\ nil) do
    require Logger
    alias MinuteModemCore.ALE.Waveform.Scrambler
    scrambler = scrambler || Scrambler.Deep.new()

    {descrambled_iq, final_scrambler, _offsets} = descramble_iq(iq_pairs, scrambler)

    {quadbits, scores} = correlate_all_blocks(descrambled_iq)

    perfect = Enum.count(scores, &(&1 >= 63.0))
    Logger.info("[SoftWalsh] #{length(scores)} blocks: #{perfect} perfect, #{length(scores) - perfect} imperfect")

    dibits = quadbits_to_dibits(quadbits)
    {dibits, final_scrambler}
  end

  # Number of equalization passes for fading channels
  @n_passes 5

  @doc """
  Decode I/Q pairs — iterative multi-pass with per-block equalization.
  Returns soft bit LLRs for soft Viterbi decoding.
  """
  def decode_iq_with_dfe(raw_iq_pairs, scrambler \\ nil) do
    require Logger
    alias MinuteModemCore.ALE.Waveform.Scrambler
    scrambler = scrambler || Scrambler.Deep.new()

    {descrambled_iq, final_scrambler, scramble_offsets} = descramble_iq(raw_iq_pairs, scrambler)

    # Use Rust correlator for multi-pass decode with soft output
    correlator = PhyModem.walsh_correlator_new(@n_phases, @n_passes)
    {quadbits, _scores, soft_bits} = PhyModem.walsh_correlator_decode_soft(
      correlator, descrambled_iq, raw_iq_pairs, scramble_offsets
    )

    # soft_bits: 384 LLRs (4 per quadbit, MSB first)
    # Convert to soft dibits: pair up as {llr1, llr2} for each coded dibit
    soft_dibits =
      soft_bits
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [l1, l2] -> {l1, l2}
        [l1] -> {l1, 0.0}
      end)

    # Also produce hard dibits for A/B comparison
    hard_dibits = quadbits_to_dibits(quadbits)

    {:soft, soft_dibits, final_scrambler, hard_dibits}
  end

  # Default turbo iterations
  @n_turbo_iterations 3

  @doc """
  Decode I/Q pairs using iterative (turbo) Walsh ↔ BCJR decoding.

  Runs DFE equalization followed by iterative exchange of extrinsic
  information between the Walsh soft correlator and a BCJR MAP decoder.
  Typically gains 2-3 dB on fading channels vs single-pass soft Viterbi.

  Returns {:turbo, hard_bits, soft_dibit_llrs, iteration_scores, scrambler}
  - hard_bits: decoded information bits from BCJR
  - soft_dibit_llrs: final coded LLRs for metric extraction
  - iteration_scores: Walsh score per iteration (convergence tracking)
  """
  def decode_iq_turbo(raw_iq_pairs, scrambler \\ nil, n_iterations \\ @n_turbo_iterations) do
    require Logger
    alias MinuteModemCore.ALE.Waveform.Scrambler
    scrambler = scrambler || Scrambler.Deep.new()

    {descrambled_iq, final_scrambler, scramble_offsets} = descramble_iq(raw_iq_pairs, scrambler)

    correlator = PhyModem.walsh_correlator_new(@n_phases, @n_passes)
    {hard_bits, soft_dibit_llrs, iteration_scores} = PhyModem.walsh_turbo_decode(
      correlator, descrambled_iq, raw_iq_pairs, scramble_offsets, n_iterations
    )

    Logger.info("[SoftWalsh] Turbo decode: #{n_iterations} iterations, " <>
      "scores=#{inspect(Enum.map(iteration_scores, &Float.round(&1, 1)))}")

    {:turbo, hard_bits, soft_dibit_llrs, iteration_scores, final_scrambler}
  end

  # ═══════════════════════════════════════════════════════════════════
  # Per-block zero-forcing equalization
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Estimate and remove the channel per Walsh block using first-pass decisions.

  For each 64-symbol block:
  1. Reconstruct the expected transmitted I/Q from the Walsh decision + scramble
  2. Estimate complex channel gain: h = Σ(r[n] × s*[n]) / Σ(|s[n]|²)
  3. Equalize: r_eq[n] = r[n] × conj(h) / |h|²

  This is a 1-tap MMSE equalizer trained on the reconstructed reference.
  It removes the bulk phase and amplitude distortion per block.
  """
  defp equalize_per_block(raw_iq, scramble_offsets, quadbits) do
    # Reconstruct the expected descrambled Walsh, then re-scramble to get tx symbols
    tx_descrambled =
      Enum.flat_map(quadbits, fn qb -> @walsh_16_full[qb] end)

    # Convert to expected I/Q (scrambled)
    tx_iq =
      Enum.zip(tx_descrambled, scramble_offsets)
      |> Enum.map(fn {sym, offset} ->
        scrambled = rem(sym + offset, 8)
        angle = scrambled * :math.pi() / 4
        {:math.cos(angle), :math.sin(angle)}
      end)

    # Process in 64-symbol blocks
    raw_blocks = Enum.chunk_every(raw_iq, 64)
    tx_blocks = Enum.chunk_every(tx_iq, 64)

    Enum.zip(raw_blocks, tx_blocks)
    |> Enum.flat_map(fn {raw_block, tx_block} ->
      if length(raw_block) == 64 and length(tx_block) == 64 do
        # Estimate complex channel: h = Σ(r × s*) / Σ(|s|²)
        {h_re, h_im, s_energy} =
          Enum.zip(raw_block, tx_block)
          |> Enum.reduce({0.0, 0.0, 0.0}, fn {{ri, rq}, {si, sq}}, {hr, hi, se} ->
            # r × conj(s) = (ri+j·rq)(si-j·sq) = (ri·si+rq·sq) + j(rq·si-ri·sq)
            {hr + ri * si + rq * sq,
             hi + rq * si - ri * sq,
             se + si * si + sq * sq}
          end)

        if s_energy > 0.01 do
          # h = (h_re + j·h_im) / s_energy
          h_re = h_re / s_energy
          h_im = h_im / s_energy
          h_mag_sq = h_re * h_re + h_im * h_im

          if h_mag_sq > 0.001 do
            # Equalize: r_eq = r × conj(h) / |h|²
            Enum.map(raw_block, fn {ri, rq} ->
              eq_i = (ri * h_re + rq * h_im) / h_mag_sq
              eq_q = (rq * h_re - ri * h_im) / h_mag_sq
              {eq_i, eq_q}
            end)
          else
            raw_block
          end
        else
          raw_block
        end
      else
        raw_block
      end
    end)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Core correlation
  # ═══════════════════════════════════════════════════════════════════

  defp correlate_all_blocks(descrambled_iq) do
    blocks = Enum.chunk_every(descrambled_iq, 64)

    blocks
    |> Enum.map(fn block ->
      if length(block) == 64 do
        {qb, score, _phase} = correlate_walsh_16_ml(block)
        {qb, score}
      else
        {0, 0.0}
      end
    end)
    |> Enum.unzip()
  end

  @doc """
  ML phase search Walsh-16 correlation on a block of 64 I/Q pairs.
  """
  def correlate_walsh_16_ml(iq_block) when length(iq_block) == 64 do
    refs = Map.new(@walsh_16_full, fn {qb, pattern} ->
      signs = Enum.map(pattern, fn sym -> if sym == 0, do: 1.0, else: -1.0 end)
      {qb, signs}
    end)

    best =
      @phase_trials
      |> Enum.flat_map(fn trial_phase ->
        cos_t = :math.cos(trial_phase)
        sin_t = :math.sin(trial_phase)

        rotated_i =
          Enum.map(iq_block, fn {i, q} ->
            i * cos_t + q * sin_t
          end)

        Enum.map(0..15, fn qb ->
          signs = refs[qb]
          score = Enum.zip(rotated_i, signs)
                  |> Enum.reduce(0.0, fn {ri, s}, acc -> acc + ri * s end)
          {qb, score, trial_phase}
        end)
      end)
      |> Enum.max_by(fn {_, score, _} -> score end)

    {qb, _raw_score, phase} = best

    cos_t = :math.cos(phase)
    sin_t = :math.sin(phase)
    hard_score =
      Enum.zip(iq_block, @walsh_16_full[qb])
      |> Enum.reduce(0, fn {{i, q}, ref_sym}, acc ->
        ri = i * cos_t + q * sin_t
        rx_sign = if ri >= 0, do: 1, else: -1
        ref_sign = if ref_sym == 0, do: 1, else: -1
        if rx_sign == ref_sign, do: acc + 1, else: acc
      end)

    {qb, hard_score / 1.0, phase}
  end

  # ═══════════════════════════════════════════════════════════════════
  # I/Q Descrambling
  # ═══════════════════════════════════════════════════════════════════

  defp descramble_iq(iq_pairs, scrambler) do
    alias MinuteModemCore.ALE.Waveform.Scrambler

    hard_symbols = Enum.map(iq_pairs, fn {i, q} -> iq_to_psk8(i, q) end)

    {_descrambled_syms, final_scrambler, scramble_offsets} =
      descramble_with_offsets(scrambler, hard_symbols)

    descrambled_iq =
      Enum.zip(iq_pairs, scramble_offsets)
      |> Enum.map(fn {{i, q}, offset} ->
        if offset == 0 do
          {i, q}
        else
          angle = -offset * :math.pi() / 4
          cos_a = :math.cos(angle)
          sin_a = :math.sin(angle)
          {i * cos_a - q * sin_a, i * sin_a + q * cos_a}
        end
      end)

    {descrambled_iq, final_scrambler, scramble_offsets}
  end

  # ═══════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════

  defp iq_to_psk8(i, q) do
    angle = :math.atan2(q, i)
    angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle
    round(angle / (:math.pi() / 4)) |> rem(8)
  end

  defp descramble_with_offsets(scrambler, symbols) do
    alias MinuteModemCore.ALE.Waveform.Scrambler

    {result_syms, final_scrambler, offsets} =
      Enum.reduce(symbols, {[], scrambler, []}, fn sym, {acc, scr, off_acc} ->
        {offset, next_scr} = Scrambler.Deep.next(scr)
        descrambled = rem(sym - offset + 8, 8)
        {[descrambled | acc], next_scr, [offset | off_acc]}
      end)

    {Enum.reverse(result_syms), final_scrambler, Enum.reverse(offsets)}
  end

  defp quadbits_to_dibits(quadbits) do
    bits = Enum.flat_map(quadbits, fn qb ->
      [(qb >>> 3) &&& 1, (qb >>> 2) &&& 1, (qb >>> 1) &&& 1, qb &&& 1]
    end)
    bits_to_dibits(bits)
  end

  defp bits_to_dibits(bits) do
    bits
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [b1, b2] -> Bitwise.bsl(b1, 1) ||| b2
      [b1] -> Bitwise.bsl(b1, 1)
    end)
  end
end
