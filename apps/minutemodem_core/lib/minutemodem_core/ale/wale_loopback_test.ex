defmodule MinuteModemCore.ALE.WaleLoopbackTest do
  @moduledoc """
  End-to-end WALE loopback test through the PHY modem.

  Tests the complete chain:
  PDU → WALE encode → 8-PSK mod → [audio] → 8-PSK demod → WALE decode → PDU

  Exercises all three decode paths:
    1. Hard Walsh + Elixir Viterbi (legacy baseline)
    2. Soft IQ + DFE + Rust soft Viterbi (production path)
    3. Turbo (BCJR iterative) decode

  Run with: MinuteModemCore.ALE.WaleLoopbackTest.run()
  """

  alias MinuteModemCore.ALE.{PDU, Waveform, Encoding}
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, SoftWalsh}
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600
  @filter_delay 12  # RRC filter delay in symbols

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║     WALE End-to-End Loopback Test                   ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    test_deep_wale_loopback()
    test_fast_wale_loopback()

    IO.puts("\n=== All Loopback Tests Complete ===\n")
    :ok
  end

  def test_deep_wale_loopback do
    IO.puts("─── Deep WALE Loopback ───")

    # Create PDU
    pdu = %PDU.LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false,
      more: false,
      equipment_class: 1,
      traffic_type: 0
    }
    pdu_binary = PDU.encode(pdu)
    IO.puts("   PDU: #{Base.encode16(pdu_binary)}")

    # Encode to WALE symbols
    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :deep,
      async: true,
      tuner_time_ms: 0,
      capture_probe_count: 1,
      preamble_count: 1
    )
    IO.puts("   Encoded: #{length(symbols)} symbols")

    # Modulate → demodulate (clean loopback)
    {frame_symbols, frame_iq} = modulate_demodulate(symbols)

    # Symbol error rate on raw symbols
    ser = symbol_error_rate(symbols, frame_symbols)
    IO.puts("   Symbol Error Rate: #{Float.round(ser * 100, 2)}%")

    # Extract data region
    data_start = 96 + 576   # capture probe + preamble
    data_len = 6144          # 96 quadbits × 64 chips

    data_symbols = Enum.slice(frame_symbols, data_start, data_len)
    data_iq = Enum.slice(frame_iq, data_start, data_len)

    # === Path 1: Hard Walsh + Elixir Viterbi (legacy) ===
    hard_pass = test_hard_decode(data_symbols, pdu_binary)
    IO.puts("   Hard decode:  #{status(hard_pass)}")

    # === Path 2: Soft IQ + DFE + Rust Viterbi (production) ===
    soft_pass = test_soft_decode(data_iq, pdu_binary)
    IO.puts("   Soft decode:  #{status(soft_pass)}")

    # === Path 3: Turbo (BCJR iterative) ===
    {turbo_pass, iter_scores} = test_turbo_decode(data_iq, pdu_binary)
    IO.puts("   Turbo decode: #{status(turbo_pass)}  iters: #{format_iters(iter_scores)}")

    IO.puts("")
  end

  def test_fast_wale_loopback do
    IO.puts("─── Fast WALE Loopback ───")

    pdu = %PDU.LsuReq{
      caller_addr: 0xABCD,
      called_addr: 0xEF01,
      voice: true,
      more: false,
      equipment_class: 2,
      traffic_type: 3
    }
    pdu_binary = PDU.encode(pdu)
    IO.puts("   PDU: #{Base.encode16(pdu_binary)}")

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :fast,
      async: true,
      tuner_time_ms: 0,
      capture_probe_count: 1
    )
    IO.puts("   Encoded: #{length(symbols)} symbols")

    {frame_symbols, _frame_iq} = modulate_demodulate(symbols)

    ser = symbol_error_rate(symbols, frame_symbols)
    IO.puts("   Symbol Error Rate: #{Float.round(ser * 100, 2)}%")

    # Fast WALE uses different data layout
    data_start = 96 + 288 + 32  # capture probe + preamble + initial probe
    data_symbols = Enum.slice(frame_symbols, data_start, length(frame_symbols) - data_start)

    # Fast WALE only has hard decode path
    dibits = FastWale.decode_data(data_symbols)
    case decode_hard_dibits_to_pdu(dibits) do
      {:ok, decoded_pdu} ->
        pass = pdu_match?(pdu, decoded_pdu)
        IO.puts("   Hard decode:  #{status(pass)}")
      {:error, reason} ->
        IO.puts("   Hard decode:  ✗ FAIL (#{inspect(reason)})")
    end

    IO.puts("")
  end

  # ===========================================================================
  # Decode paths
  # ===========================================================================

  defp test_hard_decode(data_symbols, pdu_binary) do
    {decoded_dibits, _} = DeepWale.decode_data(data_symbols)
    deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

    case viterbi_decode_hard(deinterleaved) do
      {:ok, bits} ->
        bytes = bits_to_bytes(Enum.drop(bits, -6))
        if length(bytes) >= byte_size(pdu_binary) do
          bytes |> Enum.take(byte_size(pdu_binary)) |> :erlang.list_to_binary() == pdu_binary
        else
          false
        end
      {:error, _} -> false
    end
  end

  defp test_soft_decode(data_iq, pdu_binary) do
    case SoftWalsh.decode_iq_with_dfe(data_iq) do
      {:soft, soft_dibits, _scrambler, _hard_dibits} ->
        deinterleaved = Encoding.deinterleave_soft(soft_dibits, 12, 16)
        case viterbi_decode_soft(deinterleaved) do
          {:ok, bits, _terminal} ->
            bytes = bits_to_bytes(Enum.drop(bits, -6))
            if length(bytes) >= byte_size(pdu_binary) do
              bytes |> Enum.take(byte_size(pdu_binary)) |> :erlang.list_to_binary() == pdu_binary
            else
              false
            end
          {:error, _} -> false
        end
      _ -> false
    end
  end

  defp test_turbo_decode(data_iq, pdu_binary) do
    case SoftWalsh.decode_iq_turbo(data_iq) do
      {:turbo, hard_bits, _soft_llrs, iter_scores, _scrambler} ->
        data_bits = Enum.drop(hard_bits, -6)
        bytes = bits_to_bytes(data_bits)
        pass = if length(bytes) >= byte_size(pdu_binary) do
          bytes |> Enum.take(byte_size(pdu_binary)) |> :erlang.list_to_binary() == pdu_binary
        else
          false
        end
        {pass, iter_scores}
      _ ->
        {false, []}
    end
  end

  # ===========================================================================
  # Modulation / Demodulation
  # ===========================================================================

  defp modulate_demodulate(symbols) do
    # Modulate
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush_samples = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush_samples

    # Demodulate — get both hard symbols and IQ pairs
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod, all_samples)

    demod2 = PhyModem.unified_demod_new(:psk8, @sample_rate)
    hard_symbols = PhyModem.unified_demod_symbols(demod2, all_samples)

    # Account for filter delay
    frame_symbols = Enum.slice(hard_symbols, @filter_delay, length(symbols))
    frame_iq = Enum.slice(iq_pairs, @filter_delay, length(symbols))

    {frame_symbols, frame_iq}
  end

  # ===========================================================================
  # Viterbi decoders
  # ===========================================================================

  # Hard Viterbi (Elixir, legacy)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  defp viterbi_decode_hard(dibits) do
    import Bitwise
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
    import Bitwise
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
    import Bitwise
    new_reg = (state <<< 1) ||| input_bit
    {parity(new_reg &&& @g1), parity(new_reg &&& @g2)}
  end

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> rem(2)

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  # Soft Viterbi (Elixir — same algorithm as production receiver.ex)
  defp viterbi_decode_soft(soft_dibits) do
    import Bitwise
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0.0, else: 100_000.0)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {final_metrics, final_paths} =
      Enum.reduce(soft_dibits, {initial_metrics, initial_paths}, fn soft_dibit, {metrics, paths} ->
        viterbi_step_soft(metrics, paths, soft_dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    state0 = Map.get(final_metrics, 0, 0.0)
    next_best = final_metrics |> Enum.reject(fn {s, _} -> s == 0 end) |> Enum.map(fn {_, m} -> m end) |> Enum.min(fn -> state0 end)
    {:ok, decoded, %{path_metric: state0, path_metric_delta: next_best - state0}}
  end

  defp viterbi_step_soft(metrics, paths, {llr1, llr2}) do
    import Bitwise
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = next_state &&& 1
        prev_state = next_state >>> 1
        prev_state_alt = prev_state ||| 0x20

        {exp1, exp2} = expected_output(prev_state, input_bit)
        {exp1_alt, exp2_alt} = expected_output(prev_state_alt, input_bit)

        bm = soft_bm(exp1, llr1) + soft_bm(exp2, llr2)
        bm_alt = soft_bm(exp1_alt, llr1) + soft_bm(exp2_alt, llr2)

        pm = Map.get(metrics, prev_state, 100_000.0) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 100_000.0) + bm_alt

        if pm <= pm_alt do
          {next_state, pm, [input_bit | Map.get(paths, prev_state, [])]}
        else
          {next_state, pm_alt, [input_bit | Map.get(paths, prev_state_alt, [])]}
        end
      end

    {Map.new(new_state_data, fn {s, m, _} -> {s, m} end),
     Map.new(new_state_data, fn {s, _, p} -> {s, p} end)}
  end

  defp soft_bm(expected_bit, llr), do: if(expected_bit == 1, do: -llr, else: llr)

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp decode_hard_dibits_to_pdu(dibits) do
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)
    case viterbi_decode_hard(deinterleaved) do
      {:ok, bits} ->
        data_bits = Enum.drop(bits, -6)
        bytes = bits_to_bytes(data_bits)
        if length(bytes) >= 12 do
          pdu_binary = bytes |> Enum.take(12) |> :erlang.list_to_binary()
          PDU.decode(pdu_binary)
        else
          {:error, :insufficient_bytes}
        end
      error -> error
    end
  end

  defp bits_to_bytes(bits) do
    import Bitwise
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(&(length(&1) == 8))
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        acc ||| (bit <<< (7 - idx))
      end)
    end)
  end

  defp symbol_error_rate(expected, actual) do
    min_len = min(length(expected), length(actual))
    if min_len == 0, do: 0.0, else:
      Enum.zip(Enum.take(expected, min_len), Enum.take(actual, min_len))
      |> Enum.count(fn {e, a} -> e != a end)
      |> Kernel./(min_len)
  end

  defp pdu_match?(%PDU.LsuReq{} = a, %PDU.LsuReq{} = b) do
    a.caller_addr == b.caller_addr and
    a.called_addr == b.called_addr and
    a.voice == b.voice and
    a.more == b.more
  end
  defp pdu_match?(_, _), do: false

  defp status(true), do: "✓ PASS"
  defp status(false), do: "✗ FAIL"

  defp format_iters([]), do: "—"
  defp format_iters(scores) do
    scores |> Enum.map(&Float.round(&1, 1)) |> Enum.join("→")
  end
end
