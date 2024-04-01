defmodule MinuteModemCore.ALE.LoopbackTest do
  @moduledoc """
  Test the full ALE TX/RX chain in loopback.

  Run with: mix test test/ale/loopback_test.exs
  Or in iex: MinuteModemCore.ALE.LoopbackTest.run()
  """

  alias MinuteModemCore.ALE.{PDU, Encoding, Decoding}
  alias MinuteModemCore.ALE.PDU.LsuReq
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600

  def run do
    IO.puts("\n=== ALE Full Loopback Test ===\n")

    # 1. Create a PDU
    pdu = %LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false,
      more: false,
      equipment_class: 1,
      traffic_type: 0
    }
    IO.puts("1. Original PDU: #{inspect(pdu)}")

    # 2. Encode PDU to binary
    pdu_binary = PDU.encode(pdu)
    IO.puts("2. PDU binary (#{byte_size(pdu_binary)} bytes): #{Base.encode16(pdu_binary)}")

    # 3. Encode to symbols (FEC + interleave)
    symbols = Encoding.encode_pdu(pdu_binary)
    IO.puts("3. Encoded symbols: #{length(symbols)} symbols")

    # 4. Modulate symbols to audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush_samples = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush_samples
    IO.puts("4. Modulated audio: #{length(all_samples)} samples (#{Float.round(length(all_samples) / @sample_rate * 1000, 1)}ms)")

    # 5. Demodulate
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered_symbols = PhyModem.unified_demod_symbols(demod, all_samples)
    IO.puts("5. Demodulated: #{length(recovered_symbols)} symbols")

    # 6. Account for matched filter group delay
    # TX RRC delay = 6 symbols, RX RRC delay = 6 symbols
    # Total cascade delay = 12 symbols
    filter_delay = 12
    frame_symbols = Enum.slice(recovered_symbols, filter_delay, length(symbols))
    IO.puts("6. Frame extracted: #{length(frame_symbols)} symbols (after #{filter_delay} symbol filter delay)")

    # 7. Symbol error analysis
    symbol_errors = count_errors(symbols, frame_symbols)
    ser = if length(symbols) > 0, do: symbol_errors / length(symbols) * 100, else: 0.0
    IO.puts("7. Symbol errors: #{symbol_errors}/#{length(symbols)} (SER: #{Float.round(ser, 2)}%)")

    if symbol_errors > 0 and symbol_errors <= 20 do
      mismatches = symbols
        |> Enum.zip(frame_symbols)
        |> Enum.with_index()
        |> Enum.filter(fn {{a, b}, _} -> a != b end)
        |> Enum.take(10)
      IO.puts("   Mismatches: #{inspect(mismatches)}")
    end

    # 8. Decode symbols back to PDU
    IO.puts("8. Decoding frame...")
    case Decoding.decode_pdu(frame_symbols) do
      {:ok, decoded_pdu} ->
        IO.puts("   Decoded PDU: #{inspect(decoded_pdu)}")

        if match_pdu?(pdu, decoded_pdu) do
          IO.puts("\n✅ LOOPBACK SUCCESS - PDU matches!")
          :ok
        else
          IO.puts("\n❌ LOOPBACK FAILED - PDU mismatch")
          {:error, :pdu_mismatch}
        end

      {:error, reason} ->
        IO.puts("\n❌ DECODE FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def test_modem_only do
    IO.puts("\n=== Modem-Only Test (Auto Timing) ===\n")

    # Test pattern
    pattern = [0, 1, 2, 3, 4, 5, 6, 7] |> List.duplicate(16) |> List.flatten()
    IO.puts("Pattern: #{length(pattern)} symbols")

    # Modulate
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, pattern)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush
    IO.puts("Samples: #{length(all_samples)}")

    # Demodulate
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered = PhyModem.unified_demod_symbols(demod, all_samples)
    IO.puts("Recovered: #{length(recovered)} symbols")

    # Account for filter delay (TX + RX RRC cascade)
    filter_delay = 12
    test_recovered = Enum.slice(recovered, filter_delay, length(pattern))

    errors = count_errors(pattern, test_recovered)
    IO.puts("Errors: #{errors}/#{length(pattern)} (after #{filter_delay} symbol delay)")

    if errors == 0 do
      IO.puts("\n✅ Perfect symbol recovery with auto timing!")
    else
      IO.puts("\n⚠️  #{errors} symbol errors")
      mismatches = pattern
        |> Enum.zip(test_recovered)
        |> Enum.with_index()
        |> Enum.filter(fn {{a, b}, _} -> a != b end)
        |> Enum.take(10)
      IO.puts("First mismatches: #{inspect(mismatches)}")
    end

    :ok
  end

  defp count_errors(expected, actual) do
    min_len = min(length(expected), length(actual))
    expected
    |> Enum.take(min_len)
    |> Enum.zip(Enum.take(actual, min_len))
    |> Enum.count(fn {e, a} -> e != a end)
  end

  defp match_pdu?(%LsuReq{} = a, %LsuReq{} = b) do
    a.caller_addr == b.caller_addr and
    a.called_addr == b.called_addr and
    a.voice == b.voice and
    a.more == b.more
  end

  defp match_pdu?(_, _), do: false
end
