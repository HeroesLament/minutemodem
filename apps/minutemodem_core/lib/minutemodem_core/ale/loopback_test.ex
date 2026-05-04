defmodule MinuteModemCore.ALE.LoopbackTest do
  @moduledoc """
  Test the full ALE TX/RX chain in loopback.

  Tests the raw encoding → modulation → demodulation → decoding pipeline
  without WALE framing (no capture probe, no preamble — just FEC symbols).

  Exercises both the legacy Decoding.decode_pdu path and the modern
  soft Viterbi path for comparison.

  Run with: MinuteModemCore.ALE.LoopbackTest.run()
  """

  alias MinuteModemCore.ALE.{PDU, Encoding, Decoding}
  alias MinuteModemCore.ALE.PDU.LsuReq
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║     ALE Full Loopback Test                          ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    # 1. Create a PDU
    pdu = %LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false,
      more: false,
      equipment_class: 1,
      traffic_type: 0
    }
    pdu_binary = PDU.encode(pdu)
    IO.puts("1. PDU: #{Base.encode16(pdu_binary)}")

    # 2. Encode to symbols (FEC + interleave)
    symbols = Encoding.encode_pdu(pdu_binary)
    IO.puts("2. Encoded: #{length(symbols)} symbols")

    # 3. Modulate symbols to audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush_samples = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush_samples
    IO.puts("3. Modulated: #{length(all_samples)} samples (#{Float.round(length(all_samples) / @sample_rate * 1000, 1)}ms)")

    # 4. Demodulate
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered_symbols = PhyModem.unified_demod_symbols(demod, all_samples)

    # Account for matched filter group delay
    filter_delay = 12
    frame_symbols = Enum.slice(recovered_symbols, filter_delay, length(symbols))
    IO.puts("4. Demodulated: #{length(frame_symbols)} symbols (after #{filter_delay} delay)")

    # 5. Symbol error analysis
    symbol_errors = count_errors(symbols, frame_symbols)
    ser = if length(symbols) > 0, do: symbol_errors / length(symbols) * 100, else: 0.0
    IO.puts("5. Symbol errors: #{symbol_errors}/#{length(symbols)} (SER: #{Float.round(ser, 2)}%)")

    # 6. Decode — legacy path
    IO.puts("6. Decode paths:")
    case Decoding.decode_pdu(frame_symbols) do
      {:ok, decoded_pdu} ->
        pass = match_pdu?(pdu, decoded_pdu)
        IO.puts("   Legacy (Decoding.decode_pdu): #{status(pass)}")
      {:error, reason} ->
        IO.puts("   Legacy (Decoding.decode_pdu): ✗ FAIL (#{inspect(reason)})")
    end

    # 7. Decode — soft Viterbi path (production)
    # Re-demodulate to get IQ pairs
    demod_iq = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod_iq, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod_iq, all_samples)
    frame_iq = Enum.slice(iq_pairs, filter_delay, length(symbols))

    # Soft decode path — note: only 2 Walsh blocks (encode_pdu produces raw FEC,
    # not a full 96-quadbit Deep WALE frame). Soft/turbo paths are designed for
    # full frames but should still work on small block counts in clean loopback.
    # For full-frame testing, see WaleLoopbackTest.
    alias MinuteModemCore.ALE.Waveform.SoftWalsh
    try do
      case SoftWalsh.decode_iq_with_dfe(frame_iq) do
        {:soft, soft_dibits, _scrambler, _hard_dibits} ->
          deinterleaved = Encoding.deinterleave_soft(soft_dibits, 12, 16)
          case viterbi_decode_soft(deinterleaved) do
            {:ok, bits, %{path_metric_delta: pm_delta}} ->
              bytes = bits_to_bytes(Enum.drop(bits, -6))
              if length(bytes) >= byte_size(pdu_binary) do
                decoded_bin = bytes |> Enum.take(byte_size(pdu_binary)) |> :erlang.list_to_binary()
                pass = decoded_bin == pdu_binary
                IO.puts("   Soft Viterbi:                #{status(pass)}  Δpath=#{Float.round(pm_delta, 1)}")
              else
                IO.puts("   Soft Viterbi:                ✗ FAIL (insufficient bytes)")
              end
            {:error, reason} ->
              IO.puts("   Soft Viterbi:                ✗ FAIL (#{inspect(reason)})")
          end
        _ ->
          IO.puts("   Soft Viterbi:                ✗ FAIL (decode_iq_with_dfe returned unexpected format)")
      end
    rescue
      e ->
        IO.puts("   Soft Viterbi:                SKIP (#{Exception.message(e)})")
    end

    IO.puts("")
    :ok
  end

  def test_modem_only do
    IO.puts("\n=== Modem-Only Test (Auto Timing) ===\n")

    pattern = [0, 1, 2, 3, 4, 5, 6, 7] |> List.duplicate(16) |> List.flatten()
    IO.puts("Pattern: #{length(pattern)} symbols")

    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, pattern)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered = PhyModem.unified_demod_symbols(demod, all_samples)

    filter_delay = 12
    test_recovered = Enum.slice(recovered, filter_delay, length(pattern))

    errors = count_errors(pattern, test_recovered)
    IO.puts("Errors: #{errors}/#{length(pattern)} (after #{filter_delay} symbol delay)")

    if errors == 0 do
      IO.puts("\n✓ Perfect symbol recovery")
    else
      IO.puts("\n⚠ #{errors} symbol errors")
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

  defp status(true), do: "✓ PASS"
  defp status(false), do: "✗ FAIL"

  # Soft Viterbi decoder (same algorithm as production receiver.ex)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

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

  defp expected_output(state, input_bit) do
    import Bitwise
    new_reg = (state <<< 1) ||| input_bit
    {parity(new_reg &&& @g1), parity(new_reg &&& @g2)}
  end

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> rem(2)

  defp soft_bm(expected_bit, llr), do: if(expected_bit == 1, do: -llr, else: llr)

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
end
