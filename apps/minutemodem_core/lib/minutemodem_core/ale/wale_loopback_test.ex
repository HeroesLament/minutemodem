defmodule MinuteModemCore.ALE.WaleLoopbackTest do
  @moduledoc """
  End-to-end WALE loopback test through the PHY modem.

  Tests the complete chain:
  PDU → WALE encode → 8-PSK mod → [audio] → 8-PSK demod → WALE decode → PDU

  Run with: MinuteModemCore.ALE.WaleLoopbackTest.run()
  """

  alias MinuteModemCore.ALE.{PDU, Waveform, Encoding}
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale}
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600
  @filter_delay 12  # RRC filter delay in symbols

  def run do
    IO.puts("\n=== WALE End-to-End Loopback Test ===\n")

    # Test both waveforms
    test_deep_wale_loopback()
    test_fast_wale_loopback()

    IO.puts("\n=== All Loopback Tests Complete ===\n")
  end

  def test_deep_wale_loopback do
    IO.puts("1. Testing Deep WALE loopback...")

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
    IO.puts("   Original PDU: #{inspect(pdu)}")
    IO.puts("   PDU binary: #{Base.encode16(pdu_binary)}")

    # Encode to WALE symbols
    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :deep,
      async: true,
      tuner_time_ms: 0,
      capture_probe_count: 1,
      preamble_count: 1
    )
    IO.puts("   Encoded: #{length(symbols)} symbols")

    # Modulate to audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush_samples = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush_samples
    IO.puts("   Modulated: #{length(all_samples)} samples (#{Float.round(length(all_samples) / @sample_rate * 1000, 1)}ms)")

    # Demodulate
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered_symbols = PhyModem.unified_demod_symbols(demod, all_samples)
    IO.puts("   Demodulated: #{length(recovered_symbols)} symbols")

    # Account for filter delay
    frame_symbols = Enum.slice(recovered_symbols, @filter_delay, length(symbols))
    IO.puts("   After filter delay: #{length(frame_symbols)} symbols")

    # Symbol error rate on raw symbols
    ser = symbol_error_rate(symbols, frame_symbols)
    IO.puts("   Symbol Error Rate: #{Float.round(ser * 100, 2)}%")

    # Now decode the WALE frame
    # Skip capture probe (96) and preamble (576) to get to data
    data_start = 96 + 576
    data_symbols = Enum.slice(frame_symbols, data_start, length(frame_symbols) - data_start)
    IO.puts("   Data symbols: #{length(data_symbols)}")

    # Decode Deep WALE data
    {decoded_dibits, _scrambler} = DeepWale.decode_data(data_symbols)
    IO.puts("   Decoded dibits: #{length(decoded_dibits)}")

    # Deinterleave and Viterbi decode
    case decode_dibits_to_pdu(decoded_dibits) do
      {:ok, decoded_pdu} ->
        IO.puts("   Decoded PDU: #{inspect(decoded_pdu)}")

        if pdu_match?(pdu, decoded_pdu) do
          IO.puts("   ✓ Deep WALE loopback SUCCESS!")
          :ok
        else
          IO.puts("   ✗ Deep WALE loopback FAILED - PDU mismatch")
          {:error, :pdu_mismatch}
        end

      {:error, reason} ->
        IO.puts("   ✗ Deep WALE decode FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def test_fast_wale_loopback do
    IO.puts("\n2. Testing Fast WALE loopback...")

    # Create PDU
    pdu = %PDU.LsuReq{
      caller_addr: 0xABCD,
      called_addr: 0xEF01,
      voice: true,
      more: false,
      equipment_class: 2,
      traffic_type: 3
    }
    pdu_binary = PDU.encode(pdu)
    IO.puts("   Original PDU: #{inspect(pdu)}")
    IO.puts("   PDU binary: #{Base.encode16(pdu_binary)}")

    # Encode to WALE symbols
    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :fast,
      async: true,
      tuner_time_ms: 0,
      capture_probe_count: 1
    )
    IO.puts("   Encoded: #{length(symbols)} symbols")

    # Modulate to audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush_samples = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush_samples
    IO.puts("   Modulated: #{length(all_samples)} samples (#{Float.round(length(all_samples) / @sample_rate * 1000, 1)}ms)")

    # Demodulate
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered_symbols = PhyModem.unified_demod_symbols(demod, all_samples)
    IO.puts("   Demodulated: #{length(recovered_symbols)} symbols")

    # Account for filter delay
    frame_symbols = Enum.slice(recovered_symbols, @filter_delay, length(symbols))
    IO.puts("   After filter delay: #{length(frame_symbols)} symbols")

    # Symbol error rate
    ser = symbol_error_rate(symbols, frame_symbols)
    IO.puts("   Symbol Error Rate: #{Float.round(ser * 100, 2)}%")

    # Skip capture probe (96) + preamble (288) + initial probe (32) to get to data
    data_start = 96 + 288 + 32
    data_symbols = Enum.slice(frame_symbols, data_start, length(frame_symbols) - data_start)
    IO.puts("   Data symbols: #{length(data_symbols)}")

    # Decode Fast WALE data
    dibits = FastWale.decode_data(data_symbols)
    IO.puts("   Decoded dibits: #{length(dibits)}")

    # Deinterleave and Viterbi decode
    case decode_dibits_to_pdu(dibits) do
      {:ok, decoded_pdu} ->
        IO.puts("   Decoded PDU: #{inspect(decoded_pdu)}")

        if pdu_match?(pdu, decoded_pdu) do
          IO.puts("   ✓ Fast WALE loopback SUCCESS!")
          :ok
        else
          IO.puts("   ✗ Fast WALE loopback FAILED - PDU mismatch")
          {:error, :pdu_mismatch}
        end

      {:error, reason} ->
        IO.puts("   ✗ Fast WALE decode FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ===========================================================================
  # Decode helpers
  # ===========================================================================

  defp decode_dibits_to_pdu(dibits) do
    # Use the existing Decoding module's pipeline
    # But we already have dibits, so we need to deinterleave and Viterbi decode

    # Deinterleave (12x16 matrix)
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)

    # Viterbi decode
    {:ok, bits} = viterbi_decode(deinterleaved)

    # Remove flush bits and convert to bytes
    data_bits = Enum.drop(bits, -6)
    bytes = bits_to_bytes(data_bits)

    if length(bytes) >= 12 do
      pdu_binary = bytes |> Enum.take(12) |> :erlang.list_to_binary()
      PDU.decode(pdu_binary)
    else
      {:error, :insufficient_bytes}
    end
  end

  # Viterbi decoder (copied from Decoding module since it's private)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  defp viterbi_decode(dibits) do
    import Bitwise

    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {_final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    {:ok, decoded}
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
          prev_path = Map.get(paths, prev_state, [])
          {next_state, pm, [input_bit | prev_path]}
        else
          prev_path = Map.get(paths, prev_state_alt, [])
          {next_state, pm_alt, [input_bit | prev_path]}
        end
      end

    new_metrics = Map.new(new_state_data, fn {state, metric, _} -> {state, metric} end)
    new_paths = Map.new(new_state_data, fn {state, _, path} -> {state, path} end)

    {new_metrics, new_paths}
  end

  defp expected_output(state, input_bit) do
    import Bitwise
    new_reg = (state <<< 1) ||| input_bit
    out1 = parity(new_reg &&& @g1)
    out2 = parity(new_reg &&& @g2)
    {out1, out2}
  end

  defp parity(x) do
    x
    |> Integer.digits(2)
    |> Enum.sum()
    |> rem(2)
  end

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  defp bits_to_bytes(bits) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(fn chunk -> length(chunk) == 8 end)
    |> Enum.map(fn byte_bits ->
      import Bitwise
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        acc ||| (bit <<< (7 - idx))
      end)
    end)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp symbol_error_rate(expected, actual) do
    min_len = min(length(expected), length(actual))
    errors = expected
      |> Enum.take(min_len)
      |> Enum.zip(Enum.take(actual, min_len))
      |> Enum.count(fn {e, a} -> e != a end)

    if min_len > 0, do: errors / min_len, else: 0.0
  end

  defp pdu_match?(%PDU.LsuReq{} = a, %PDU.LsuReq{} = b) do
    a.caller_addr == b.caller_addr and
    a.called_addr == b.called_addr and
    a.voice == b.voice and
    a.more == b.more
  end
  defp pdu_match?(_, _), do: false
end
