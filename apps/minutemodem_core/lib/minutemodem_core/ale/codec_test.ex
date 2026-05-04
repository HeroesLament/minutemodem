defmodule MinuteModemCore.ALE.CodecTest do
  @moduledoc """
  Deep WALE Codec Go/No-Go Test Suite.

  Tests the encode/decode pipeline in isolation — no modulation, no channel.
  Verifies Walsh-16, interleaver, convolutional code, and Viterbi decoder.

  ## Tests

  - C1: Clean codec roundtrip (encode → decode, no errors)
  - C2: Walsh-16 noise margin (how many symbol errors before miscorrelation)
  - C3: Interleaver roundtrip (interleave → deinterleave)
  - C4: Interleaver burst spreading (measures how bursts get dispersed)
  - C5: Viterbi error correction capacity (random BER threshold)
  - C6: Viterbi + interleaver under burst errors
  - C7: Full codec under realistic fading error pattern
  """

  alias MinuteModemCore.ALE.Encoding
  alias MinuteModemCore.ALE.Waveform.{DeepWale, Walsh}
  alias MinuteModemCore.ALE.Scrambler

  import Bitwise

  # Generator polynomials for Viterbi (must match Encoding module)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  @test_pdu <<0x40, 0x00, 0x34, 0x12, 0x78, 0x56, 0x00, 0x00, 0x00, 0x00, 0x3B, 0xDC>>

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║     Deep WALE Codec Go/No-Go Test Suite             ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    results = [
      c1_clean_roundtrip(),
      c2_walsh_noise_margin(),
      c3_interleaver_roundtrip(),
      c4_interleaver_burst_spread(),
      c5_viterbi_random_ber(),
      c6_viterbi_interleaver_burst(),
      c7_full_codec_fading_pattern()
    ]

    passed = Enum.count(results, &(&1 == :pass))
    failed = Enum.count(results, &(&1 == :fail))

    IO.puts("\n═══════════════════════════════════════════════════════")
    IO.puts("  Results: #{passed} passed, #{failed} failed out of #{length(results)}")
    IO.puts("═══════════════════════════════════════════════════════\n")

    if failed == 0, do: :ok, else: :fail
  end

  # ===========================================================================
  # C1: Clean Codec Roundtrip
  # ===========================================================================

  def c1_clean_roundtrip do
    IO.puts("─── C1: Clean codec roundtrip ────────────────────────")
    pdu = @test_pdu

    # Encode: PDU → conv encode → interleave → quadbits → Walsh-16 → scramble
    symbols = DeepWale.encode_data(pdu)
    IO.puts("   Encoded: #{length(symbols)} symbols from #{byte_size(pdu)} byte PDU")

    # Decode: descramble → Walsh correlate → quadbits → bits → deinterleave → Viterbi
    {decoded_dibits, _} = DeepWale.decode_data(symbols)
    deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

    case viterbi_decode(deinterleaved) do
      {:ok, bits} ->
        bytes = bits_to_bytes(Enum.drop(bits, -6))
        decoded_bin = bytes |> Enum.take(byte_size(pdu)) |> :erlang.list_to_binary()

        if decoded_bin == pdu do
          IO.puts("   C1: ✓ PASS — clean roundtrip perfect")
          :pass
        else
          IO.puts("   C1: ✗ FAIL — data mismatch")
          IO.puts("     Expected: #{Base.encode16(pdu)}")
          IO.puts("     Got:      #{Base.encode16(decoded_bin)}")
          :fail
        end

      {:error, reason} ->
        IO.puts("   C1: ✗ FAIL — Viterbi error: #{inspect(reason)}")
        :fail
    end
  end

  # ===========================================================================
  # C2: Walsh-16 Noise Margin
  # ===========================================================================

  def c2_walsh_noise_margin do
    IO.puts("\n─── C2: Walsh-16 noise margin ─────────────────────────")

    # For each error count 0..32, test all 16 quadbits
    results =
      for n_errors <- [0, 5, 10, 15, 20, 25, 28, 30, 32] do
        correct_count = test_walsh_error_resilience(n_errors, 100)
        pct = Float.round(correct_count / (16 * 100) * 100, 1)
        IO.puts("   #{String.pad_leading("#{n_errors}", 2)} errors/64: #{pct}% correct (#{correct_count}/#{16 * 100})")
        {n_errors, correct_count, 16 * 100}
      end

    # Pass criteria: correct decode up to 20 errors (31% SER in Walsh block)
    {_, correct_at_20, total_at_20} = Enum.find(results, fn {n, _, _} -> n == 20 end)
    pct_at_20 = correct_at_20 / total_at_20

    if pct_at_20 > 0.95 do
      IO.puts("   C2: ✓ PASS — Walsh-16 tolerates 20/64 errors (#{Float.round(pct_at_20 * 100, 1)}% correct)")
      :pass
    else
      IO.puts("   C2: ✗ FAIL — Walsh-16 only #{Float.round(pct_at_20 * 100, 1)}% correct at 20 errors")
      :fail
    end
  end

  defp test_walsh_error_resilience(n_errors, trials_per_quadbit) do
    Enum.sum(
      for quadbit <- 0..15 do
        ref = Walsh.walsh_16(quadbit)

        correct =
          for _ <- 1..trials_per_quadbit do
            corrupted = inject_symbol_errors(ref, n_errors)
            {decoded_qb, _score} = Walsh.correlate_walsh_16(corrupted)
            if decoded_qb == quadbit, do: 1, else: 0
          end
          |> Enum.sum()

        correct
      end
    )
  end

  defp inject_symbol_errors(symbols, n_errors) do
    len = length(symbols)
    # Pick n_errors unique random positions
    positions = Enum.take_random(0..(len - 1), min(n_errors, len)) |> MapSet.new()

    symbols
    |> Enum.with_index()
    |> Enum.map(fn {sym, idx} ->
      if MapSet.member?(positions, idx) do
        # Flip to a different symbol (add random offset 1-7)
        rem(sym + Enum.random(1..7), 8)
      else
        sym
      end
    end)
  end

  # ===========================================================================
  # C3: Interleaver Roundtrip
  # ===========================================================================

  def c3_interleaver_roundtrip do
    IO.puts("\n─── C3: Interleaver roundtrip ─────────────────────────")

    # Test with the actual Deep WALE parameters: 12 rows × 16 cols = 192 dibits
    original = Enum.map(0..191, fn i -> rem(i * 7 + 3, 4) end)

    interleaved = Encoding.interleave(original, 12, 16)
    recovered = Encoding.deinterleave(interleaved, 12, 16)

    # Also verify interleaving actually shuffles (not identity)
    shuffled = Enum.zip(original, interleaved) |> Enum.count(fn {a, b} -> a != b end)

    if recovered == original do
      IO.puts("   Roundtrip: exact match (#{length(original)} dibits)")
      IO.puts("   Shuffled: #{shuffled}/#{length(original)} positions changed by interleaving")
      IO.puts("   C3: ✓ PASS")
      :pass
    else
      mismatches = Enum.zip(original, recovered) |> Enum.count(fn {a, b} -> a != b end)
      IO.puts("   C3: ✗ FAIL — #{mismatches} mismatches after roundtrip")
      :fail
    end
  end

  # ===========================================================================
  # C4: Interleaver Burst Spreading
  # ===========================================================================

  def c4_interleaver_burst_spread do
    IO.puts("\n─── C4: Interleaver burst spreading ──────────────────")

    # Create a clean sequence, mark a burst of consecutive errors,
    # then deinterleave to see how the burst gets spread.
    capacity = 12 * 16  # 192

    for burst_len <- [12, 16, 24, 32, 48, 64] do
      # Create error mask: 1 = error, 0 = clean
      # Place burst starting at position 0 (worst case)
      error_mask = List.duplicate(1, burst_len) ++ List.duplicate(0, capacity - burst_len)

      # Deinterleave the error mask to see where errors land
      deinterleaved_mask = Encoding.deinterleave(error_mask, 12, 16)

      # Find max consecutive errors after deinterleaving
      max_consecutive = max_run(deinterleaved_mask, 1)

      # Find the spread: how many positions have errors
      total_errors = Enum.count(deinterleaved_mask, &(&1 == 1))

      IO.puts("   Burst #{String.pad_leading("#{burst_len}", 2)}: → max consecutive=#{max_consecutive}, spread over #{total_errors} positions")
    end

    # Test the critical case: burst of 64 (one complete Walsh block wiped out)
    error_mask = List.duplicate(1, 64) ++ List.duplicate(0, 192 - 64)
    deinterleaved = Encoding.deinterleave(error_mask, 12, 16)
    max_run_64 = max_run(deinterleaved, 1)

    if max_run_64 <= 8 do
      IO.puts("   C4: ✓ PASS — 64-symbol burst spreads to max #{max_run_64} consecutive")
      :pass
    else
      IO.puts("   C4: ✗ FAIL — 64-symbol burst still has #{max_run_64} consecutive after deinterleave")
      :fail
    end
  end

  defp max_run(list, value) do
    list
    |> Enum.chunk_by(&(&1 == value))
    |> Enum.filter(fn chunk -> hd(chunk) == value end)
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  # ===========================================================================
  # C5: Viterbi Error Correction (Random BER)
  # ===========================================================================

  def c5_viterbi_random_ber do
    IO.puts("\n─── C5: Viterbi error correction (random BER) ────────")
    pdu = @test_pdu

    # Conv encode the PDU
    dibits = Encoding.conv_encode_with_flush(pdu)
    IO.puts("   Encoded: #{length(dibits)} dibits from #{byte_size(pdu)} byte PDU")

    for ber <- [0.0, 0.02, 0.05, 0.08, 0.10, 0.15, 0.20, 0.25] do
      # Run multiple trials for statistical significance
      n_trials = 20
      successes = Enum.count(1..n_trials, fn _ ->
        corrupted = inject_dibit_ber(dibits, ber)
        case viterbi_decode(corrupted) do
          {:ok, bits} ->
            bytes = bits_to_bytes(Enum.drop(bits, -6))
            decoded_bin = bytes |> Enum.take(byte_size(pdu)) |> :erlang.list_to_binary()
            decoded_bin == pdu
          _ -> false
        end
      end)

      IO.puts("   BER #{String.pad_trailing(Float.to_string(ber * 100) <> "%", 6)}: #{successes}/#{n_trials} successful decodes")
    end

    # Pass criteria: 100% success at 5% BER
    n_trials = 50
    successes_5pct = Enum.count(1..n_trials, fn _ ->
      corrupted = inject_dibit_ber(dibits, 0.05)
      case viterbi_decode(corrupted) do
        {:ok, bits} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          decoded_bin = bytes |> Enum.take(byte_size(pdu)) |> :erlang.list_to_binary()
          decoded_bin == pdu
        _ -> false
      end
    end)

    if successes_5pct == n_trials do
      IO.puts("   C5: ✓ PASS — Viterbi corrects 5% random BER (#{successes_5pct}/#{n_trials})")
      :pass
    else
      IO.puts("   C5: ✗ FAIL — Viterbi only #{successes_5pct}/#{n_trials} at 5% BER")
      :fail
    end
  end

  defp inject_dibit_ber(dibits, ber) do
    Enum.map(dibits, fn dibit ->
      if :rand.uniform() < ber do
        # Flip one or both bits of the dibit
        case Enum.random(1..3) do
          1 -> Bitwise.bxor(dibit, 0b01)
          2 -> Bitwise.bxor(dibit, 0b10)
          3 -> Bitwise.bxor(dibit, 0b11)
        end
      else
        dibit
      end
    end)
  end

  # ===========================================================================
  # C6: Viterbi + Interleaver Under Burst Errors
  # ===========================================================================

  def c6_viterbi_interleaver_burst do
    IO.puts("\n─── C6: Viterbi + interleaver under burst errors ─────")
    pdu = @test_pdu

    # Full encode path: conv encode → interleave
    dibits = Encoding.conv_encode_with_flush(pdu)
    interleaved = Encoding.interleave(dibits, 12, 16)
    IO.puts("   Encoded + interleaved: #{length(interleaved)} dibits")

    for burst_len <- [0, 12, 24, 32, 48, 64, 96, 128, 160] do
      n_trials = 20
      successes = Enum.count(1..n_trials, fn trial ->
        # Place burst at random position
        start = if burst_len == 0, do: 0, else: :rand.uniform(max(length(interleaved) - burst_len, 1)) - 1

        corrupted = inject_burst_errors(interleaved, start, burst_len)

        # Deinterleave → Viterbi
        deinterleaved = Encoding.deinterleave(corrupted, 12, 16)
        case viterbi_decode(deinterleaved) do
          {:ok, bits} ->
            bytes = bits_to_bytes(Enum.drop(bits, -6))
            decoded_bin = bytes |> Enum.take(byte_size(pdu)) |> :erlang.list_to_binary()
            decoded_bin == pdu
          _ -> false
        end
      end)

      pct = Float.round(successes / n_trials * 100, 0)
      IO.puts("   Burst #{String.pad_leading("#{burst_len}", 3)} dibits: #{successes}/#{n_trials} (#{pct}%)")
    end

    # Pass criteria: survive burst of 32 dibits (16.7% of codeword)
    n_trials = 50
    successes = Enum.count(1..n_trials, fn _ ->
      start = :rand.uniform(max(length(interleaved) - 32, 1)) - 1
      corrupted = inject_burst_errors(interleaved, start, 32)
      deinterleaved = Encoding.deinterleave(corrupted, 12, 16)
      case viterbi_decode(deinterleaved) do
        {:ok, bits} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          decoded_bin = bytes |> Enum.take(byte_size(pdu)) |> :erlang.list_to_binary()
          decoded_bin == pdu
        _ -> false
      end
    end)

    if successes >= n_trials * 0.9 do
      IO.puts("   C6: ✓ PASS — survives 32-dibit burst (#{successes}/#{n_trials})")
      :pass
    else
      IO.puts("   C6: ✗ FAIL — only #{successes}/#{n_trials} at 32-dibit burst")
      :fail
    end
  end

  defp inject_burst_errors(dibits, start, burst_len) do
    dibits
    |> Enum.with_index()
    |> Enum.map(fn {dibit, idx} ->
      if idx >= start and idx < start + burst_len do
        Bitwise.bxor(dibit, Enum.random(1..3))
      else
        dibit
      end
    end)
  end

  # ===========================================================================
  # C7: Full Codec Under Realistic Fading Error Pattern
  # ===========================================================================

  def c7_full_codec_fading_pattern do
    IO.puts("\n─── C7: Full codec under realistic fading pattern ────")
    pdu = @test_pdu

    # Full encode: PDU → conv encode → interleave → quadbits → Walsh-16 → scramble
    symbols = DeepWale.encode_data(pdu)
    IO.puts("   Encoded: #{length(symbols)} symbols")

    # Define error patterns matching what we observed in H3a:
    # Pattern A: 40% of blocks in deep fade (random errors), 60% clean
    # Pattern B: Contiguous deep fade of ~40 blocks (40 × 64 = 2560 symbols)
    # Pattern C: Moderate SER everywhere (~30% per block, no deep fades)

    patterns = [
      {"A: 40% blocks faded (scattered)", &pattern_scattered_fades/1},
      {"B: 40 contiguous faded blocks", &pattern_contiguous_fade/1},
      {"C: 30% SER everywhere (uniform)", &pattern_uniform_ser/1},
      {"D: 20% SER everywhere", &(pattern_uniform_ser_n(&1, 0.20))},
      {"E: 10% SER everywhere", &(pattern_uniform_ser_n(&1, 0.10))},
      {"F: H3a-like (phase-dependent)", &pattern_h3a_like/1}
    ]

    results = for {name, pattern_fn} <- patterns do
      n_trials = 20
      successes = Enum.count(1..n_trials, fn _ ->
        corrupted = pattern_fn.(symbols)
        try_decode(corrupted, pdu)
      end)

      ser = estimate_ser(symbols, pattern_fn)
      IO.puts("   #{name}: #{successes}/#{n_trials} decoded, ~#{Float.round(ser * 100, 1)}% SER")
      {name, successes, n_trials}
    end

    # Pass criteria: Pattern E (10% SER everywhere) should decode
    {_, successes_e, trials_e} = Enum.find(results, fn {n, _, _} -> String.starts_with?(n, "E:") end)

    if successes_e >= trials_e * 0.8 do
      IO.puts("   C7: ✓ PASS — codec handles 10% uniform SER (#{successes_e}/#{trials_e})")
      :pass
    else
      IO.puts("   C7: ✗ FAIL — codec fails at 10% uniform SER (#{successes_e}/#{trials_e})")
      :fail
    end
  end

  # Pattern A: 40% of 64-symbol blocks completely randomized
  defp pattern_scattered_fades(symbols) do
    symbols
    |> Enum.chunk_every(64)
    |> Enum.map(fn block ->
      if :rand.uniform() < 0.4 do
        Enum.map(block, fn _ -> Enum.random(0..7) end)
      else
        block
      end
    end)
    |> List.flatten()
  end

  # Pattern B: 40 contiguous blocks (2560 symbols) completely randomized
  defp pattern_contiguous_fade(symbols) do
    fade_start = 20  # block 20
    fade_end = 60    # block 60

    symbols
    |> Enum.chunk_every(64)
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      if idx >= fade_start and idx < fade_end do
        Enum.map(block, fn _ -> Enum.random(0..7) end)
      else
        block
      end
    end)
    |> List.flatten()
  end

  # Pattern C: 30% SER everywhere (uniform random errors)
  defp pattern_uniform_ser(symbols) do
    pattern_uniform_ser_n(symbols, 0.30)
  end

  defp pattern_uniform_ser_n(symbols, ser) do
    Enum.map(symbols, fn sym ->
      if :rand.uniform() < ser do
        rem(sym + Enum.random(1..7), 8)
      else
        sym
      end
    end)
  end

  # Pattern F: H3a-like — good periods and deep fade periods, phase-based
  defp pattern_h3a_like(symbols) do
    symbols
    |> Enum.chunk_every(64)
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      # Simulate fading cycle: ~2.8s period, 96 blocks total = ~2.56s
      # Good: blocks 0-10, 25-37, 78-95
      # Bad:  blocks 11-24, 38-77
      phase = rem(idx, 96)
      ser = cond do
        phase < 10 -> 0.05
        phase < 25 -> 0.87
        phase < 37 -> 0.05
        phase < 77 -> 0.87
        true -> 0.05
      end

      Enum.map(block, fn sym ->
        if :rand.uniform() < ser do
          rem(sym + Enum.random(1..7), 8)
        else
          sym
        end
      end)
    end)
    |> List.flatten()
  end

  defp try_decode(symbols, expected_pdu) do
    {decoded_dibits, _} = DeepWale.decode_data(symbols)
    deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

    case viterbi_decode(deinterleaved) do
      {:ok, bits} ->
        bytes = bits_to_bytes(Enum.drop(bits, -6))
        decoded_bin = bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary()
        decoded_bin == expected_pdu
      _ -> false
    end
  end

  defp estimate_ser(symbols, pattern_fn) do
    corrupted = pattern_fn.(symbols)
    errors = Enum.zip(symbols, corrupted) |> Enum.count(fn {a, b} -> a != b end)
    errors / length(symbols)
  end

  # ===========================================================================
  # Viterbi Decoder (copy from test harness)
  # ===========================================================================

  defp viterbi_decode(dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {_, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    {:ok, Map.get(final_paths, 0, []) |> Enum.reverse()}
  end

  defp viterbi_step(metrics, paths, received_dibit) do
    received = {(received_dibit >>> 1) &&& 1, received_dibit &&& 1}

    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = next_state &&& 1
        prev_state = next_state >>> 1
        prev_state_alt = prev_state ||| 0x20

        exp = expected_output(prev_state, input_bit)
        exp_alt = expected_output(prev_state_alt, input_bit)

        bm = hamming_distance(exp, received)
        bm_alt = hamming_distance(exp_alt, received)

        pm = Map.get(metrics, prev_state, 10000) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 10000) + bm_alt

        if pm <= pm_alt do
          {next_state, pm, [input_bit | Map.get(paths, prev_state, [])]}
        else
          {next_state, pm_alt, [input_bit | Map.get(paths, prev_state_alt, [])]}
        end
      end

    {Map.new(new_state_data, fn {s, m, _} -> {s, m} end),
     Map.new(new_state_data, fn {s, _, p} -> {s, p} end)}
  end

  defp expected_output(state, input_bit) do
    new_reg = (state <<< 1) ||| input_bit
    {parity(new_reg &&& @g1), parity(new_reg &&& @g2)}
  end

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> rem(2)

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  defp bits_to_bytes(bits) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(&(length(&1) == 8))
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        acc ||| (bit <<< (7 - idx))
      end)
    end)
  end
end
