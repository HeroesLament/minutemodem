defmodule MinuteModemCore.ALE.DeepWaleChannelTest do
  @moduledoc """
  Deep WALE channel loopback test.

  Tests the full pipeline: PDU → encode → mod → Watterson channel → demod → decode
  with controlled channel parameters to isolate failure modes.

  Uses RPC to the simnet node for the Watterson channel NIF.

  Hypotheses tested:
    H1: Mod→demod without channel works perfectly (baseline)
    H2: Watterson channel causes decode failures
    H3a: Fading (not noise) is the dominant impairment
    H3b: Noise (not fading) is the dominant impairment
    H4: Symbol error pattern shows burst structure from fading

  Run:  MinuteModemCore.ALE.DeepWaleChannelTest.run()
  """

  require Logger

  alias MinuteModemCore.ALE.{PDU, Waveform}
  alias MinuteModemCore.ALE.Waveform.DeepWale
  alias MinuteModemCore.ALE.Encoding
  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Rig.SimnetClient

  alias MinuteModemCore.ALE.Waveform.SoftWalsh

  @sample_rate 9600
  @filter_delay 12
  # Channel FIR group delay: 129-tap FIR → (129-1)/2 = 64 samples = 16 symbols at 4 samp/sym
  @channel_symbol_delay 16

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║     Deep WALE Channel Loopback Test Suite           ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available. Start simnet first.")
      :error
    else
      {symbols, pdu_binary} = make_deep_wale_frame()
      IO.puts("Frame: #{length(symbols)} symbols, PDU: #{Base.encode16(pdu_binary)}\n")

      h1_no_channel(symbols, pdu_binary)
      h0_channel_passthrough(symbols)
      h2_watterson(symbols, pdu_binary)
      h3a_fading_only(symbols, pdu_binary)
      h3b_noise_only(symbols, pdu_binary)
      h4_symbol_error_analysis(symbols, pdu_binary)
      h5_hf_demod_comparison(symbols, pdu_binary)

      IO.puts("\n=== Test Suite Complete ===\n")
    end
  end

  # ===========================================================================
  # Test Cases
  # ===========================================================================

  def h1_no_channel(symbols, pdu_binary) do
    IO.puts("─── H1: Baseline (no channel) ────────────────────────")
    {frame_symbols, _, frame_iq} = modulate_demodulate(symbols, nil)
    analyze_result_full("H1", symbols, frame_symbols, frame_iq, pdu_binary)
  end

  def h0_channel_passthrough(symbols) do
    IO.puts("─── H0: Channel format diagnostic ────────────────────")

    # Minimal test: send a simple known pattern through the channel
    node = SimnetClient.simnet_node()
    {:ok, ch} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :create, [
      %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 0.0,
        snr_db: 80.0, carrier_freq_hz: 1800.0}, 42
    ])

    # Send 300 samples of a 1800 Hz tone at amplitude 0.5
    # (need enough to allow for 63-sample group delay from 127-tap FIR)
    test_samples = for i <- 0..299 do
      0.5 * :math.cos(2 * :math.pi() * 1800.0 / 9600.0 * i)
    end
    test_bin = Enum.into(test_samples, <<>>, fn s -> <<s::native-float-32>> end)

    {:ok, out_bin} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :process_block, [ch, test_bin])
    :rpc.call(node, MinutemodemSimnet.Physics.Channel, :destroy, [ch])

    out_samples = for <<f::native-float-32 <- out_bin>>, do: f

    # Find best offset by minimizing error (group delay is ~63 for 127-tap FIR)
    skip = 100
    best = Enum.map(0..130, fn off ->
      pairs = Enum.zip(Enum.drop(test_samples, skip), Enum.drop(out_samples, skip + off))
      avg_err = Enum.map(pairs, fn {a, b} -> abs(a - b) end) |> Enum.sum() |> Kernel./(length(pairs))
      {off, avg_err}
    end) |> Enum.min_by(fn {_, e} -> e end)
    {best_off, _best_err} = best

    IO.puts("   Echo test (1800Hz tone, amp=0.5, 80dB SNR, no fading):")
    IO.puts("   IN  [#{skip}..#{skip+9}]: #{inspect(Enum.slice(test_samples, skip, 10) |> Enum.map(&Float.round(&1, 4)))}")
    IO.puts("   OUT [#{skip+best_off}..#{skip+best_off+9}]: #{inspect(Enum.slice(out_samples, skip + best_off, 10) |> Enum.map(&Float.round(&1, 4)))}")

    diffs = Enum.zip(Enum.drop(test_samples, skip), Enum.drop(out_samples, skip + best_off))
      |> Enum.map(fn {a, b} -> abs(a - b) end)
    IO.puts("   Best offset: #{best_off}, Max error: #{Float.round(Enum.max(diffs), 6)}")

    # Measure carrier phase offset using properly aligned samples
    n = length(test_samples)
    w = 2.0 * :math.pi() * 1800.0 / 9600.0
    measure_start = skip + best_off
    {cos_corr, sin_corr} = Enum.slice(out_samples, measure_start, 50)
      |> Enum.with_index(measure_start)
      |> Enum.reduce({0.0, 0.0}, fn {s, i}, {cc, sc} ->
        {cc + s * :math.cos(w * i), sc + s * :math.sin(w * i)}
      end)
    phase_offset_rad = :math.atan2(-sin_corr, cos_corr)
    phase_offset_deg = phase_offset_rad * 180.0 / :math.pi()
    IO.puts("   Carrier phase offset: #{Float.round(phase_offset_deg, 2)}° (#{Float.round(phase_offset_rad, 4)} rad)")
    psk8_sector = 360.0 / 8
    IO.puts("   8-PSK sector: #{Float.round(psk8_sector, 1)}°, offset/sector: #{Float.round(phase_offset_deg / psk8_sector, 2)}")
    IO.puts("")

    # ═══ SIDEBAND REFLECTION TEST ═══
    # Theory: real mixer loses sideband sign. A tone below the carrier (1200 Hz)
    # should come out at 1200 Hz, but if sidebands are reflected, it will
    # appear at 2×1800 - 1200 = 2400 Hz instead.
    IO.puts("   Sideband reflection test:")
    for {test_freq, label} <- [{1200.0, "below carrier"}, {2400.0, "above carrier"}, {600.0, "far below"}, {1000.0, "800 below"}] do
      ch_sb = rpc_create_channel(0.0, 0.0, 80.0)
      # Generate 400 samples of tone at test_freq (need >127 for FIR settling)
      sb_samples = for i <- 0..399 do
        0.5 * :math.cos(2 * :math.pi() * test_freq / 9600.0 * i)
      end
      sb_bin = Enum.into(sb_samples, <<>>, fn s -> <<s::native-float-32>> end)
      {:ok, sb_out_bin} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :process_block, [ch_sb, sb_bin])
      rpc_destroy_channel(ch_sb)
      sb_out = for <<f::native-float-32 <- sb_out_bin>>, do: f

      # Measure energy at original freq and at mirrored freq (2*1800 - test_freq)
      mirror_freq = 2 * 1800.0 - test_freq
      skip = 200
      window = Enum.slice(sb_out, skip, 150)

      # Correlate with original frequency
      {c_orig, s_orig} = window
        |> Enum.with_index(skip)
        |> Enum.reduce({0.0, 0.0}, fn {s, i}, {cc, sc} ->
          {cc + s * :math.cos(2 * :math.pi() * test_freq / 9600.0 * i),
           sc + s * :math.sin(2 * :math.pi() * test_freq / 9600.0 * i)}
        end)
      energy_orig = :math.sqrt(c_orig * c_orig + s_orig * s_orig) / length(window)

      # Correlate with mirror frequency
      {c_mirr, s_mirr} = window
        |> Enum.with_index(skip)
        |> Enum.reduce({0.0, 0.0}, fn {s, i}, {cc, sc} ->
          {cc + s * :math.cos(2 * :math.pi() * mirror_freq / 9600.0 * i),
           sc + s * :math.sin(2 * :math.pi() * mirror_freq / 9600.0 * i)}
        end)
      energy_mirr = :math.sqrt(c_mirr * c_mirr + s_mirr * s_mirr) / length(window)

      status = cond do
        energy_orig > energy_mirr * 3 -> "✓ correct freq dominant"
        energy_mirr > energy_orig * 3 -> "✗ MIRRORED! (sideband reflected)"
        true -> "⚠ mixed (both present)"
      end

      IO.puts("     #{label} (#{round(test_freq)} Hz): orig=#{Float.round(energy_orig, 4)}, mirror(#{round(mirror_freq)} Hz)=#{Float.round(energy_mirr, 4)} #{status}")
    end
    IO.puts("")
    IO.puts("   Pure f32 roundtrip test (no channel, just i16→f32→i16):")
    mod2 = PhyModem.unified_mod_new(:psk8, @sample_rate)
    tx_i16 = PhyModem.unified_mod_modulate(mod2, symbols) ++ PhyModem.unified_mod_flush(mod2)

    # Convert i16 → f32 → i16 (no channel)
    roundtrip_i16 = Enum.map(tx_i16, fn s ->
      f = s / 32768.0
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end)

    rt_diffs = Enum.zip(tx_i16, roundtrip_i16) |> Enum.map(fn {a, b} -> abs(a - b) end)
    rt_max = Enum.max(rt_diffs)
    rt_bad = Enum.count(rt_diffs, &(&1 > 0))
    IO.puts("   Max |diff|: #{rt_max}, samples with any diff: #{rt_bad}/#{length(tx_i16)}")

    # Now convert to f32 binary and back (same as apply_channel but skip RPC)
    f32_bin_local = Enum.into(tx_i16, <<>>, fn s -> <<(s / 32768.0)::native-float-32>> end)
    local_rt = for <<f::native-float-32 <- f32_bin_local>> do
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end

    lt_diffs = Enum.zip(tx_i16, local_rt) |> Enum.map(fn {a, b} -> abs(a - b) end)
    lt_max = Enum.max(lt_diffs)
    lt_bad = Enum.count(lt_diffs, &(&1 > 0))
    IO.puts("   Via binary: Max |diff|: #{lt_max}, samples with any diff: #{lt_bad}/#{length(tx_i16)}")

    # Compare first 10 samples via binary
    IO.puts("   TX first 10: #{inspect(Enum.take(tx_i16, 10))}")
    IO.puts("   RT first 10: #{inspect(Enum.take(local_rt, 10))}")

    # Demod the local roundtrip (should be identical to H1 = 0% SER)
    demod_local = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recov_local = PhyModem.unified_demod_symbols(demod_local, local_rt)
    frame_local = Enum.slice(recov_local, @filter_delay, length(symbols))
    ser_local = symbol_error_rate(symbols, frame_local)
    IO.puts("   SER of local f32 roundtrip: #{Float.round(ser_local * 100, 2)}%")

    # Now send through channel and demod
    IO.puts("")
    IO.puts("   Channel roundtrip + demod:")
    ch_test = rpc_create_channel(0.0, 0.0, 60.0)
    f32_out_test = rpc_process_block(ch_test, f32_bin_local)
    rpc_destroy_channel(ch_test)

    # Compare f32 values: output is DELAYED relative to input by ~63 samples
    # So output[i+offset] should match input[i]
    in_f32 = for <<f::native-float-32 <- f32_bin_local>>, do: f
    out_f32 = for <<f::native-float-32 <- f32_out_test>>, do: f

    # Search for best offset (output delayed relative to input)
    best_f32_off = Enum.map(0..130, fn off ->
      pairs = Enum.zip(in_f32, Enum.drop(out_f32, off))
      |> Enum.drop(100)  # skip settling
      avg = Enum.map(pairs, fn {a, b} -> abs(a - b) end) |> Enum.sum() |> Kernel./(max(length(pairs) - 100, 1))
      {off, avg}
    end) |> Enum.min_by(fn {_, e} -> e end)
    {best_off_f32, best_avg_f32} = best_f32_off

    IO.puts("   f32 best match: offset=#{best_off_f32}, avg|diff|=#{Float.round(best_avg_f32, 6)}")

    # Show a few key offsets
    for offset <- [0, 63, best_off_f32] |> Enum.uniq() do
      pairs = Enum.zip(in_f32, Enum.drop(out_f32, offset)) |> Enum.drop(100)
      diffs = Enum.map(pairs, fn {a, b} -> abs(a - b) end)
      avg = Enum.sum(diffs) / max(length(diffs), 1)
      bad = Enum.count(diffs, &(&1 > 0.01))
      IO.puts("   f32 [out offset=#{offset}]: Avg=#{Float.round(avg, 6)}, >0.01: #{bad}/#{length(diffs)}")
    end

    IO.puts("   f32 IN  [100..109]: #{inspect(Enum.slice(in_f32, 100, 10) |> Enum.map(&Float.round(&1, 5)))}")
    IO.puts("   f32 OUT [163..172]: #{inspect(Enum.slice(out_f32, 163, 10) |> Enum.map(&Float.round(&1, 5)))}")

    ch_rt = for <<f::native-float-32 <- f32_out_test>> do
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end

    demod_ch = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recov_ch = PhyModem.unified_demod_symbols(demod_ch, ch_rt)
    frame_ch = Enum.slice(recov_ch, @filter_delay + @channel_symbol_delay, length(symbols))
    ser_ch = symbol_error_rate(symbols, frame_ch)
    IO.puts("   SER of channel roundtrip: #{Float.round(ser_ch * 100, 2)}%")
    IO.puts("")

    # Modulate to i16 audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples_i16 = PhyModem.unified_mod_modulate(mod, symbols) ++ PhyModem.unified_mod_flush(mod)

    IO.puts("   TX samples: #{length(samples_i16)}")
    IO.puts("   TX range: #{Enum.min(samples_i16)}..#{Enum.max(samples_i16)}")

    # Convert to f32 and send through a benign channel (no fading, 60dB SNR)
    channel_id = rpc_create_channel(0.0, 0.0, 60.0)

    f32_in = Enum.into(samples_i16, <<>>, fn s ->
      <<(s / 32768.0)::native-float-32>>
    end)
    IO.puts("   f32 input bytes: #{byte_size(f32_in)}")

    f32_out = rpc_process_block(channel_id, f32_in)
    IO.puts("   f32 output bytes: #{byte_size(f32_out)}")

    rpc_destroy_channel(channel_id)

    # Convert back to i16
    out_i16 = for <<f::native-float-32 <- f32_out>> do
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end

    IO.puts("   RX samples: #{length(out_i16)}")
    IO.puts("   RX range: #{Enum.min(out_i16)}..#{Enum.max(out_i16)}")

    # Compare first 20 samples
    IO.puts("   TX first 10: #{inspect(Enum.take(samples_i16, 10))}")
    IO.puts("   RX first 10: #{inspect(Enum.take(out_i16, 10))}")

    # Sample-level error
    min_len = min(length(samples_i16), length(out_i16))
    if min_len > 0 do
      diffs = Enum.zip(Enum.take(samples_i16, min_len), Enum.take(out_i16, min_len))
        |> Enum.map(fn {a, b} -> abs(a - b) end)
      avg_diff = Enum.sum(diffs) / min_len
      max_diff = Enum.max(diffs)
      IO.puts("   [No offset] Avg |diff|: #{Float.round(avg_diff, 1)}, Max |diff|: #{max_diff}")

      big_diffs = Enum.count(diffs, &(&1 > 100))
      IO.puts("   [No offset] Samples with |diff| > 100: #{big_diffs}/#{min_len} (#{Float.round(big_diffs/min_len * 100, 1)}%)")

      # Try with FIR group delay offsets (63 samples for 127-tap, plus neighbors)
      for offset <- [15, 16, 31, 32, 62, 63, 64, 95, 96, 127] do
        shifted_tx = Enum.drop(samples_i16, offset)
        shifted_len = min(length(shifted_tx), length(out_i16))
        if shifted_len > 100 do
          shifted_diffs = Enum.zip(Enum.take(shifted_tx, shifted_len), Enum.take(out_i16, shifted_len))
            |> Enum.map(fn {a, b} -> abs(a - b) end)
          shifted_avg = Enum.sum(shifted_diffs) / shifted_len
          shifted_big = Enum.count(shifted_diffs, &(&1 > 100))
          IO.puts("   [Offset #{offset}] Avg |diff|: #{Float.round(shifted_avg, 1)}, bad: #{shifted_big}/#{shifted_len} (#{Float.round(shifted_big/shifted_len * 100, 1)}%)")
        end
      end
    end
    IO.puts("")

    # Symbol-level offset search through clean channel
    IO.puts("   Symbol alignment search (clean channel → demod):")
    clean_ch2 = rpc_create_channel(0.0, 0.0, 60.0)
    impaired2 = apply_channel(samples_i16, clean_ch2)
    rpc_destroy_channel(clean_ch2)

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered = PhyModem.unified_demod_symbols(demod, impaired2)
    IO.puts("   Recovered #{length(recovered)} symbols from #{length(symbols)} TX symbols")

    best_offset = Enum.min_by(0..60, fn offset ->
      frame = Enum.slice(recovered, offset, length(symbols))
      symbol_error_rate(symbols, frame)
    end)

    best_ser = symbol_error_rate(symbols, Enum.slice(recovered, best_offset, length(symbols)))
    baseline_ser = symbol_error_rate(symbols, Enum.slice(recovered, @filter_delay, length(symbols)))
    IO.puts("   Offset #{@filter_delay} (current): SER=#{Float.round(baseline_ser * 100, 2)}%")
    IO.puts("   Offset #{best_offset} (best):    SER=#{Float.round(best_ser * 100, 2)}%")
  end

  def h2_watterson(symbols, pdu_binary) do
    IO.puts("─── H2: Watterson (delay=2ms, doppler=0.5Hz, SNR=15dB) ──")
    channel_id = rpc_create_channel(2.0, 0.5, 15.0)
    {frame_symbols, _, _} = modulate_demodulate(symbols, channel_id)
    analyze_result("H2", symbols, frame_symbols, pdu_binary)
    rpc_destroy_channel(channel_id)
  end

  def h3a_fading_only(symbols, pdu_binary) do
    IO.puts("─── H3a: Fading only (doppler=0.5Hz, SNR=50dB) ──────")
    channel_id = rpc_create_channel(2.0, 0.5, 50.0)
    {frame_symbols, _, _} = modulate_demodulate(symbols, channel_id)
    analyze_result("H3a", symbols, frame_symbols, pdu_binary)
    rpc_destroy_channel(channel_id)
  end

  def h3b_noise_only(symbols, pdu_binary) do
    IO.puts("─── H3b: Noise only (no fading, SNR=15dB) ───────────")
    channel_id = rpc_create_channel(0.0, 0.0, 15.0)
    {frame_symbols, _, _} = modulate_demodulate(symbols, channel_id)
    analyze_result("H3b", symbols, frame_symbols, pdu_binary)
    rpc_destroy_channel(channel_id)
  end

  def h4_symbol_error_analysis(symbols, _pdu_binary) do
    IO.puts("─── H4: Symbol error distribution under fading ──────")
    channel_id = rpc_create_channel(2.0, 0.5, 15.0)
    {frame_symbols, _, _} = modulate_demodulate(symbols, channel_id)
    rpc_destroy_channel(channel_id)

    data_start = 96 + 576
    data_len = 6144

    tx_data = Enum.slice(symbols, data_start, data_len)
    rx_data = Enum.slice(frame_symbols, data_start, data_len)

    if length(rx_data) < data_len do
      IO.puts("   SKIP: insufficient demodulated symbols (got #{length(rx_data)}, need #{data_len})")
    else
      block_errors =
        Enum.zip(Enum.chunk_every(tx_data, 64), Enum.chunk_every(rx_data, 64))
        |> Enum.with_index()
        |> Enum.map(fn {{tx_block, rx_block}, idx} ->
          errors = Enum.zip(tx_block, rx_block) |> Enum.count(fn {t, r} -> t != r end)
          {idx, errors, length(tx_block)}
        end)

      IO.puts("   Block SER% (#{length(block_errors)} blocks of 64 symbols):")

      block_errors
      |> Enum.chunk_every(8)
      |> Enum.with_index()
      |> Enum.each(fn {group, gi} ->
        rates = Enum.map(group, fn {_idx, errs, total} ->
          pct = round(errs / total * 100)
          String.pad_leading("#{pct}", 3)
        end) |> Enum.join(" ")
        s = gi * 8
        IO.puts("   #{String.pad_leading("#{s}", 2)}: #{rates}")
      end)

      total_errors = Enum.map(block_errors, fn {_, e, _} -> e end) |> Enum.sum()
      total_syms = Enum.map(block_errors, fn {_, _, t} -> t end) |> Enum.sum()
      bad_blocks = Enum.count(block_errors, fn {_, e, t} -> e / t > 0.3 end)
      burst = find_longest_burst(block_errors, 0.3)

      IO.puts("   Overall SER: #{Float.round(total_errors / total_syms * 100, 2)}%")
      IO.puts("   Bad blocks (>30% SER): #{bad_blocks}/#{length(block_errors)}")
      IO.puts("   Longest bad burst: #{burst} blocks (#{burst * 64} syms, #{Float.round(burst * 64 / 2400 * 1000, 0)}ms)")
    end
    IO.puts("")
  end

  def h5_hf_demod_comparison(symbols, pdu_binary) do
    IO.puts("─── H5: HF Demod with DFE Equalizer ─────────────────")
    IO.puts("   Comparing basic demod vs HF demod (with DFE equalizer)")
    IO.puts("")

    # H5a: Clean channel — HF demod should also be 0%
    IO.puts("   H5a: Clean channel (60dB SNR, no fading):")
    ch = rpc_create_channel(0.0, 0.0, 60.0)
    {frame_hf, _} = modulate_demodulate_hf(symbols, ch)
    ser_hf = symbol_error_rate(symbols, frame_hf)
    IO.puts("     HF demod SER: #{Float.round(ser_hf * 100, 2)}%")
    rpc_destroy_channel(ch)
    IO.puts("")

    # H5b: Fading only — the real test for the equalizer
    IO.puts("   H5b: Fading only (doppler=0.5Hz, SNR=50dB):")
    ch_fade = rpc_create_channel(2.0, 0.5, 50.0)

    {frame_basic, _, _} = modulate_demodulate(symbols, ch_fade)
    ser_basic = symbol_error_rate(symbols, frame_basic)
    rpc_destroy_channel(ch_fade)

    ch_fade2 = rpc_create_channel(2.0, 0.5, 50.0)
    {frame_hf2, _} = modulate_demodulate_hf(symbols, ch_fade2)
    ser_hf2 = symbol_error_rate(symbols, frame_hf2)
    rpc_destroy_channel(ch_fade2)

    IO.puts("     Basic demod SER: #{Float.round(ser_basic * 100, 2)}%")
    IO.puts("     HF demod SER:    #{Float.round(ser_hf2 * 100, 2)}%")
    IO.puts("")

    # H5c: Full Watterson
    IO.puts("   H5c: Watterson (delay=2ms, doppler=0.5Hz, SNR=15dB):")
    ch_w = rpc_create_channel(2.0, 0.5, 15.0)
    {frame_w_basic, _, frame_w_iq} = modulate_demodulate(symbols, ch_w)
    ser_w_basic = symbol_error_rate(symbols, frame_w_basic)
    rpc_destroy_channel(ch_w)

    ch_w2 = rpc_create_channel(2.0, 0.5, 15.0)
    {frame_w_hf, _} = modulate_demodulate_hf(symbols, ch_w2)
    ser_w_hf = symbol_error_rate(symbols, frame_w_hf)
    rpc_destroy_channel(ch_w2)

    IO.puts("     Basic demod SER: #{Float.round(ser_w_basic * 100, 2)}%")
    IO.puts("     HF demod SER:    #{Float.round(ser_w_hf * 100, 2)}%")

    # Full decode comparison on basic demod (has IQ for soft/turbo)
    analyze_result_full("H5c", symbols, frame_w_basic, frame_w_iq, pdu_binary)
  end

  # ===========================================================================
  # RPC to simnet node for Watterson channel NIF
  # ===========================================================================

  defp rpc_create_channel(delay_spread_ms, doppler_hz, snr_db) do
    node = SimnetClient.simnet_node()
    delay_samples = round(delay_spread_ms * @sample_rate / 1000)
    seed = :rand.uniform(1_000_000)

    params = %{
      sample_rate: @sample_rate,
      delay_spread_samples: delay_samples,
      doppler_bandwidth_hz: doppler_hz,
      snr_db: snr_db,
      carrier_freq_hz: 1800.0
    }

    {:ok, channel_id} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :create, [params, seed])
    channel_id
  end

  defp rpc_process_block(channel_id, f32_binary) do
    node = SimnetClient.simnet_node()
    {:ok, output} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :process_block, [channel_id, f32_binary])
    output
  end

  defp rpc_destroy_channel(channel_id) do
    node = SimnetClient.simnet_node()
    :rpc.call(node, MinutemodemSimnet.Physics.Channel, :destroy, [channel_id])
  end

  # ===========================================================================
  # Pipeline
  # ===========================================================================

  defp make_deep_wale_frame do
    pdu = %PDU.LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false,
      more: false,
      equipment_class: 0,
      traffic_type: 0
    }
    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: :deep,
      async: true,
      tuner_time_ms: 0,
      capture_probe_count: 1,
      preamble_count: 1
    )
    {symbols, pdu_binary}
  end

  defp modulate_demodulate(symbols, channel_id) do
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    impaired = if channel_id do
      channel_pad = List.duplicate(0, @channel_symbol_delay * 4 + 16)
      apply_channel(all_samples ++ channel_pad, channel_id)
    else
      all_samples
    end

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    recovered = PhyModem.unified_demod_symbols(demod, impaired)

    # Also get IQ pairs for soft/turbo decode
    demod_iq = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod_iq, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod_iq, impaired)

    total_delay = if channel_id, do: @filter_delay + @channel_symbol_delay, else: @filter_delay
    frame = Enum.slice(recovered, total_delay, length(symbols))
    frame_iq = Enum.slice(iq_pairs, total_delay, length(symbols))
    {frame, impaired, frame_iq}
  end

  # DFE center-tap delay: ff_taps/2 = 21/2 = 10 symbols for hf_skywave config
  @dfe_delay 10

  # Same as modulate_demodulate but uses HF demodulator with DFE equalizer
  # and feeds the known preamble as training symbols
  defp modulate_demodulate_hf(symbols, channel_id) do
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    impaired = if channel_id do
      # Extra padding for channel delay + DFE fill-up
      channel_pad = List.duplicate(0, (@channel_symbol_delay + @dfe_delay) * 4 + 16)
      apply_channel(all_samples ++ channel_pad, channel_id)
    else
      all_samples
    end

    # Use HF demodulator with DFE equalizer
    demod = PhyModem.unified_demod_new_hf(:psk8, @sample_rate)

    # The DFE has a center-tap delay of @dfe_delay symbols.
    # The demod emits @filter_delay warmup symbols, then the DFE adds @dfe_delay more.
    # Training symbols must be aligned: the DFE output at index N corresponds to
    # the input symbol at index N - @dfe_delay. During warmup (first @filter_delay
    # outputs), the input is garbage, so we pad. After warmup, output[k] = input[k - @dfe_delay].
    # For training, the DFE's train() is called with training_symbols[k], and the DFE
    # output corresponds to input[k - @dfe_delay]. So training_symbols[k] should be
    # the symbol that was at input position k - @dfe_delay.
    #
    # Simplest approach: don't use training, let CMA converge blindly.
    # The Rust tests showed CMA + DD works once symbols start flowing.
    # Training only helps if we account for the delay perfectly.

    recovered = PhyModem.unified_demod_symbols(demod, impaired)
    # Total delay: RRC filter + channel FIR + DFE center tap
    total_delay = @filter_delay + @dfe_delay + if(channel_id, do: @channel_symbol_delay, else: 0)
    frame = Enum.slice(recovered, total_delay, length(symbols))
    {frame, impaired}
  end

  defp apply_channel(samples_i16, channel_id) do
    # i16 → f32 binary (normalized to [-1,1])
    f32_bin = Enum.into(samples_i16, <<>>, fn s ->
      <<(s / 32768.0)::native-float-32>>
    end)

    output_bin = rpc_process_block(channel_id, f32_bin)

    # f32 binary → i16 list
    for <<f::native-float-32 <- output_bin>> do
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end
  end

  # ===========================================================================
  # Analysis
  # ===========================================================================

  defp analyze_result(label, tx_symbols, rx_symbols, pdu_binary) do
    min_len = min(length(tx_symbols), length(rx_symbols))

    if min_len < length(tx_symbols) do
      IO.puts("   WARNING: got #{length(rx_symbols)} syms, expected #{length(tx_symbols)}")
    end

    ser = symbol_error_rate(tx_symbols, rx_symbols)
    IO.puts("   SER: #{Float.round(ser * 100, 2)}% (#{min_len} symbols)")

    data_start = 96 + 576
    data_len = 6144
    data_symbols = Enum.slice(rx_symbols, data_start, data_len)

    if length(data_symbols) >= data_len do
      # Hard decode (legacy)
      {decoded_dibits, _} = DeepWale.decode_data(data_symbols)
      deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

      case viterbi_decode(deinterleaved) do
        {:ok, bits} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          if length(bytes) >= 12 do
            decoded_bin = bytes |> Enum.take(12) |> :erlang.list_to_binary()
            if decoded_bin == pdu_binary do
              IO.puts("   #{label} (hard): ✓ DECODE SUCCESS")
            else
              IO.puts("   #{label} (hard): ✗ DECODE FAIL — data mismatch")
            end
          else
            IO.puts("   #{label} (hard): ✗ DECODE FAIL — insufficient bytes")
          end
        {:error, reason} ->
          IO.puts("   #{label} (hard): ✗ DECODE FAIL — #{inspect(reason)}")
      end
    else
      IO.puts("   #{label}: SKIP — insufficient data symbols")
    end
    IO.puts("")
  end

  # Extended analysis with soft IQ and turbo paths.
  # Requires IQ pairs from demodulator.
  defp analyze_result_full(label, tx_symbols, rx_symbols, rx_iq, pdu_binary) do
    alias MinuteModemCore.ALE.Waveform.SoftWalsh

    min_len = min(length(tx_symbols), length(rx_symbols))

    ser = symbol_error_rate(tx_symbols, rx_symbols)
    IO.puts("   SER: #{Float.round(ser * 100, 2)}% (#{min_len} symbols)")

    data_start = 96 + 576
    data_len = 6144
    data_symbols = Enum.slice(rx_symbols, data_start, data_len)
    data_iq = Enum.slice(rx_iq, data_start, data_len)

    if length(data_symbols) < data_len do
      IO.puts("   #{label}: SKIP — insufficient data symbols")
      IO.puts("")
    else
      # === Hard decode (legacy) ===
      {decoded_dibits, _} = DeepWale.decode_data(data_symbols)
      deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)
      hard_pass = case viterbi_decode(deinterleaved) do
        {:ok, bits} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          length(bytes) >= 12 and (bytes |> Enum.take(12) |> :erlang.list_to_binary()) == pdu_binary
        _ -> false
      end
      IO.puts("   #{label} hard:  #{if hard_pass, do: "✓", else: "✗"}")

      # === Soft IQ + DFE (production) ===
      soft_pass = if length(data_iq) >= data_len do
        case SoftWalsh.decode_iq_with_dfe(data_iq) do
          {:soft, soft_dibits, _scr, _hard} ->
            deint_soft = Encoding.deinterleave_soft(soft_dibits, 12, 16)
            case viterbi_decode_soft(deint_soft) do
              {:ok, bits, _terminal} ->
                bytes = bits_to_bytes(Enum.drop(bits, -6))
                length(bytes) >= 12 and (bytes |> Enum.take(12) |> :erlang.list_to_binary()) == pdu_binary
              _ -> false
            end
          _ -> false
        end
      else
        false
      end
      IO.puts("   #{label} soft:  #{if soft_pass, do: "✓", else: "✗"}")

      # === Turbo (BCJR iterative) ===
      {turbo_pass, iter_info} = if length(data_iq) >= data_len do
        case SoftWalsh.decode_iq_turbo(data_iq) do
          {:turbo, hard_bits, _llrs, iter_scores, _scr} ->
            bytes = bits_to_bytes(Enum.drop(hard_bits, -6))
            pass = length(bytes) >= 12 and (bytes |> Enum.take(12) |> :erlang.list_to_binary()) == pdu_binary
            scores_str = iter_scores |> Enum.map(&Float.round(&1, 0)) |> Enum.join("→")
            {pass, scores_str}
          _ -> {false, "—"}
        end
      else
        {false, "—"}
      end
      IO.puts("   #{label} turbo: #{if turbo_pass, do: "✓", else: "✗"}  [#{iter_info}]")

      IO.puts("")
    end
  end

  defp symbol_error_rate(expected, actual) do
    min_len = min(length(expected), length(actual))
    if min_len == 0, do: 0.0, else:
      Enum.zip(Enum.take(expected, min_len), Enum.take(actual, min_len))
      |> Enum.count(fn {e, a} -> e != a end)
      |> Kernel./(min_len)
  end

  defp find_longest_burst(block_errors, threshold) do
    block_errors
    |> Enum.map(fn {_, errs, total} -> errs / total > threshold end)
    |> Enum.chunk_by(& &1)
    |> Enum.filter(fn chunk -> hd(chunk) end)
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  # ===========================================================================
  # Viterbi decoders
  # ===========================================================================

  # Soft Viterbi (same algorithm as production receiver.ex)
  defp viterbi_decode_soft(soft_dibits) do
    import Bitwise
    initial_metrics = Map.new(0..63, fn s ->
      {s, if(s == 0, do: 0.0, else: 100_000.0)}
    end)
    initial_paths = Map.new(0..63, fn s -> {s, []} end)

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
    g1 = 0b1011011
    g2 = 0b1111001
    new_state_data =
      for next_state <- 0..63 do
        input_bit = next_state &&& 1
        prev_state = next_state >>> 1
        prev_state_alt = prev_state ||| 0x20

        prev_reg = (prev_state <<< 1) ||| input_bit
        prev_reg_alt = (prev_state_alt <<< 1) ||| input_bit
        {exp1, exp2} = {parity(prev_reg &&& g1), parity(prev_reg &&& g2)}
        {exp1_alt, exp2_alt} = {parity(prev_reg_alt &&& g1), parity(prev_reg_alt &&& g2)}

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

  # Hard Viterbi (legacy)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  defp viterbi_decode(dibits) do
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
