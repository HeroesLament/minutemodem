defmodule MinuteModemCore.ALE.PllBlockSweep do
  @moduledoc """
  Sweep phase estimator block size to find optimal value.
  Tests each block size at multiple SNRs on AWGN channel.

  Run: MinuteModemCore.ALE.PllBlockSweep.run()
  """

  alias MinuteModemCore.ALE.{PDU, Waveform}
  alias MinuteModemCore.ALE.Waveform.DeepWale
  alias MinuteModemCore.ALE.Encoding
  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Rig.SimnetClient

  import Bitwise

  @sample_rate 9600
  @filter_delay 12
  @channel_symbol_delay 16
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  @block_sizes [1, 4, 8, 16, 32, 64, 128, 256]
  @snrs [-9, -7, -6, -3, 0, 3]
  @trials_per_point 10

  def run(opts \\ []) do
    block_sizes = Keyword.get(opts, :block_sizes, @block_sizes)
    snrs = Keyword.get(opts, :snrs, @snrs)
    trials = Keyword.get(opts, :trials, @trials_per_point)

    IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
    IO.puts("║  PLL Phase Block Size Sweep                                ║")
    IO.puts("║  #{length(block_sizes)} block sizes × #{length(snrs)} SNRs × #{trials} trials                        ║")
    IO.puts("╚══════════════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available")
      :error
    else
      {symbols, pdu_binary} = make_frame()

      header = ["BlkSz" | Enum.map(snrs, fn s -> "#{s}dB" end)] |> Enum.join("\t")
      IO.puts(header)
      IO.puts(String.duplicate("─", String.length(header) + length(snrs) * 4))

      results =
        for bs <- block_sizes do
          row =
            for snr <- snrs do
              successes =
                Enum.count(1..trials, fn _ ->
                  run_trial(symbols, pdu_binary, snr, bs)
                end)
              {snr, successes, trials}
            end

          cells = Enum.map(row, fn {_snr, s, t} ->
            pct = round(s / t * 100)
            "#{pct}%"
          end)
          IO.puts(["#{bs}" | cells] |> Enum.join("\t"))

          {bs, row}
        end

      IO.puts("")

      telem_results =
        for bs <- block_sizes do
          {avg_lock, avg_err} = run_telemetry_trial(symbols, -6.0, bs)
          IO.puts("BS=#{bs}\tavg_lock=#{Float.round(avg_lock, 3)}\tavg_abs_err=#{Float.round(avg_err, 4)} rad")
          {bs, avg_lock, avg_err}
        end

      IO.puts("\nDone.")
      {results, telem_results}
    end
  end

  defp make_frame do
    pdu = %PDU.LsuReq{
      caller_addr: 0x1234, called_addr: 0x5678,
      voice: false, more: false, equipment_class: 0, traffic_type: 0
    }
    pdu_binary = PDU.encode(pdu)
    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :deep, async: true, tuner_time_ms: 0,
      capture_probe_count: 1, preamble_count: 1)
    {symbols, pdu_binary}
  end

  defp run_trial(symbols, pdu_binary, snr_db, block_size) do
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    channel_id = create_channel(0.0, 0.0, snr_db)
    pad = List.duplicate(0, @channel_symbol_delay * 4 + 16)
    impaired = apply_channel(all_samples ++ pad, channel_id)
    destroy_channel(channel_id)

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, block_size)
    recovered = PhyModem.unified_demod_symbols(demod, impaired)

    total_delay = @filter_delay + @channel_symbol_delay
    frame = Enum.slice(recovered, total_delay, length(symbols))

    decode_frame(frame, pdu_binary)
  end

  defp run_telemetry_trial(symbols, snr_db, block_size) do
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    channel_id = create_channel(0.0, 0.0, snr_db)
    pad = List.duplicate(0, @channel_symbol_delay * 4 + 16)
    impaired = apply_channel(all_samples ++ pad, channel_id)
    destroy_channel(channel_id)

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, block_size)
    PhyModem.unified_demod_enable_telemetry(demod)
    _recovered = PhyModem.unified_demod_symbols(demod, impaired)
    telem = PhyModem.unified_demod_take_telemetry(demod)

    if length(telem) > 0 do
      avg_lock = telem
        |> Enum.map(fn {_, _, _, _, _, _, lock} -> lock end)
        |> Enum.sum()
        |> Kernel./(length(telem))

      avg_err = telem
        |> Enum.map(fn {_, _, _, _, pe, _, _} -> abs(pe) end)
        |> Enum.sum()
        |> Kernel./(length(telem))

      {avg_lock, avg_err}
    else
      {0.0, 0.0}
    end
  end

  defp decode_frame(rx_symbols, expected_pdu) do
    data_start = 96 + 576
    data_len = 6144
    data_symbols = Enum.slice(rx_symbols, data_start, data_len)

    if length(data_symbols) < data_len do
      false
    else
      {decoded_dibits, _} = DeepWale.decode_data(data_symbols)
      deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

      case viterbi_decode(deinterleaved) do
        {:ok, bits} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          if length(bytes) >= byte_size(expected_pdu) do
            decoded_bin = bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary()
            decoded_bin == expected_pdu
          else
            false
          end
        _ -> false
      end
    end
  end

  defp create_channel(delay_ms, doppler_hz, snr_db) do
    node = SimnetClient.simnet_node()
    delay_samples = round(delay_ms * @sample_rate / 1000)
    {:ok, channel_id} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :create, [
      %{sample_rate: @sample_rate, delay_spread_samples: delay_samples,
        doppler_bandwidth_hz: doppler_hz, snr_db: snr_db, carrier_freq_hz: 1800.0},
      :rand.uniform(1_000_000)
    ])
    channel_id
  end

  defp destroy_channel(channel_id) do
    node = SimnetClient.simnet_node()
    :rpc.call(node, MinutemodemSimnet.Physics.Channel, :destroy, [channel_id])
  end

  defp apply_channel(samples_i16, channel_id) do
    node = SimnetClient.simnet_node()
    f32_bin = Enum.into(samples_i16, <<>>, fn s -> <<(s / 32768.0)::native-float-32>> end)
    {:ok, out} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :process_block, [channel_id, f32_bin])
    for <<f::native-float-32 <- out>>, do: round(f * 32768.0) |> max(-32768) |> min(32767)
  end

  defp viterbi_decode(dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s -> {s, if(s == 0, do: 0, else: 10000)} end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)
    {_, final_paths} = Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {m, p} -> viterbi_step(m, p, dibit) end)
    {:ok, Map.get(final_paths, 0, []) |> Enum.reverse()}
  end

  defp viterbi_step(metrics, paths, received_dibit) do
    received = {(received_dibit >>> 1) &&& 1, received_dibit &&& 1}
    new = for next_state <- 0..(@num_states - 1) do
      input_bit = next_state &&& 1
      ps = next_state >>> 1
      ps_alt = ps ||| 0x20
      exp = expected_output(ps, input_bit)
      exp_alt = expected_output(ps_alt, input_bit)
      bm = hamming(exp, received)
      bm_alt = hamming(exp_alt, received)
      pm = Map.get(metrics, ps, 10000) + bm
      pm_alt = Map.get(metrics, ps_alt, 10000) + bm_alt
      if pm <= pm_alt do
        {next_state, pm, [input_bit | Map.get(paths, ps, [])]}
      else
        {next_state, pm_alt, [input_bit | Map.get(paths, ps_alt, [])]}
      end
    end
    {Map.new(new, fn {s, m, _} -> {s, m} end), Map.new(new, fn {s, _, p} -> {s, p} end)}
  end

  defp expected_output(state, input_bit) do
    new_reg = (state <<< 1) ||| input_bit
    {parity(new_reg &&& @g1), parity(new_reg &&& @g2)}
  end

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> rem(2)
  defp hamming({a1, a2}, {b1, b2}), do: (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)

  defp bits_to_bytes(bits) do
    bits |> Enum.chunk_every(8) |> Enum.filter(&(length(&1) == 8))
    |> Enum.map(fn bb -> Enum.reduce(Enum.with_index(bb), 0, fn {b, i}, acc -> acc ||| (b <<< (7 - i)) end) end)
  end
end
