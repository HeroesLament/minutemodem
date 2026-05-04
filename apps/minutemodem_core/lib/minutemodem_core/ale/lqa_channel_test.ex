defmodule MinuteModemCore.ALE.LQAChannelTest do
  @moduledoc """
  LQA Score Characterization over Watterson Channel Models.

  Pushes Deep WALE frames through real simnet Watterson channels (AWGN,
  Good, Poor) at varying SNR and measures the LQA scores that come out
  of the decode pipeline. This answers the question: does LQA.score
  actually correlate with link quality?

  The test produces a mapping:
    channel_type × SNR → {lqa_score, link_probability, decode_metrics}

  This lets us calibrate the scoring weights and set thresholds for
  automatic channel selection.

  Requires simnet node to be running.

  Run:
    MinuteModemCore.ALE.LQAChannelTest.run()          # Quick (10 trials)
    MinuteModemCore.ALE.LQAChannelTest.run(:full)      # Full (50 trials)
    MinuteModemCore.ALE.LQAChannelTest.run(:awgn)      # AWGN only
    MinuteModemCore.ALE.LQAChannelTest.run(:good)      # Good only
    MinuteModemCore.ALE.LQAChannelTest.run(:poor)      # Poor only
    MinuteModemCore.ALE.LQAChannelTest.characterize()   # Extended sweep + DB recording
  """

  require Logger

  alias MinuteModemCore.ALE.{PDU, Waveform, LQA}
  alias MinuteModemCore.ALE.Waveform.{DeepWale, SoftWalsh}
  alias MinuteModemCore.ALE.Encoding
  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Rig.SimnetClient

  import Bitwise

  @sample_rate 9600
  @filter_delay 12
  @channel_symbol_delay 16
  @rig_id "lqa-channel-test"

  # Viterbi constants (same as compliance test)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  # ═══════════════════════════════════════════════════════════════════
  # Channel Definitions (ITU-R F.1487)
  # ═══════════════════════════════════════════════════════════════════

  @channels %{
    awgn: %{name: "AWGN", delay_ms: 0.0, doppler_hz: 0.0},
    good: %{name: "Good (0.5ms/0.5Hz)", delay_ms: 0.5, doppler_hz: 0.5},
    poor: %{name: "Poor (2.0ms/1.0Hz)", delay_ms: 2.0, doppler_hz: 1.0}
  }

  # SNR sweep points per channel type — fine-grained, deep into noise floor
  @snr_points %{
    awgn: [-18, -16, -15, -14, -13, -12, -11, -10, -9, -8, -7, -6, -5, -3, 0, 3, 6, 10, 15],
    good: [-15, -13, -12, -11, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0, 2, 4, 6, 10],
    poor: [-12, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 6, 10]
  }

  # Frequencies for DB recording (simulated channel assignments)
  @test_freqs %{
    awgn: 7_102_000,
    good: 14_109_000,
    poor: 21_096_000
  }

  # ═══════════════════════════════════════════════════════════════════
  # Entry Points
  # ═══════════════════════════════════════════════════════════════════

  def run(mode \\ :quick)
  def run(:quick), do: run_suite(20, [:awgn, :good, :poor])
  def run(:full), do: run_suite(50, [:awgn, :good, :poor])
  def run(:awgn), do: run_suite(20, [:awgn])
  def run(:good), do: run_suite(20, [:good])
  def run(:poor), do: run_suite(20, [:poor])

  # Turbo modes — run both standard and turbo decode, show comparison
  def run(:turbo_awgn), do: run_suite_turbo(20, [:awgn])
  def run(:turbo_good), do: run_suite_turbo(20, [:good])
  def run(:turbo_poor), do: run_suite_turbo(20, [:poor])
  def run(:turbo), do: run_suite_turbo(20, [:awgn, :good, :poor])

  @doc """
  Extended characterization: run sweep, record observations to LQA DB,
  then show what rank_channels would produce.
  """
  def characterize(n_trials \\ 20) do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║  LQA Channel Characterization + DB Recording        ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available")
      :error
    else
      all_results = run_suite(n_trials, [:awgn, :good, :poor])

      # Show what rank_channels would produce given the recorded data
      IO.puts("\n─── Channel Ranking from Recorded Data ───")
      test_channels = Enum.map(@test_freqs, fn {_type, freq} ->
        %{freq_hz: freq, name: "test", mode: :usb}
      end)

      # Use addr 0x1234 (the caller in our test frames)
      ranked = LQA.rank_channels(@rig_id, 0x1234, test_channels)
      for ch <- ranked do
        ch_name = Enum.find(@test_freqs, fn {_, f} -> f == ch.freq_hz end) |> elem(0)
        IO.puts("  #{ch_name} (#{format_freq(ch.freq_hz)}): score=#{ch.score}, count=#{ch.count}")
      end

      all_results
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Suite Runner
  # ═══════════════════════════════════════════════════════════════════

  defp run_suite_turbo(n_trials, channel_types) do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║  Standard vs Turbo Decode Comparison                ║")
    IO.puts("║  Trials per point: #{String.pad_leading("#{n_trials}", 3)}                               ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available.")
      :error
    else
      all_channel_summaries = for ch_type <- channel_types do
        ch = @channels[ch_type]
        snrs = @snr_points[ch_type]

        IO.puts("─── #{ch.name} Channel ───")
        IO.puts("   SNR     Std Link%  Turbo Link%  Std Score  Turbo Score  Δ Score  Turbo Iters")
        IO.puts("   ────    ─────────  ───────────  ─────────  ───────────  ───────  ───────────")

        snr_rows = for snr <- snrs do
          # Run trials getting both standard and turbo results
          results = for _ <- 1..n_trials do
            try do
              run_single_trial_both(ch.delay_ms, ch.doppler_hz, snr)
            rescue
              e ->
                Logger.debug("[LQA Turbo] Trial crashed: #{inspect(e)}")
                {%{decoded: false, lqa_score: 0.0}, %{decoded: false, lqa_score: 0.0, iteration_scores: []}}
            end
          end

          std_results = Enum.map(results, &elem(&1, 0))
          turbo_results = Enum.map(results, &elem(&1, 1))

          std_successes = Enum.count(std_results, & &1.decoded)
          turbo_successes = Enum.count(turbo_results, & &1.decoded)

          std_scores = Enum.map(std_results, & &1.lqa_score)
          turbo_scores = Enum.map(turbo_results, & &1.lqa_score)

          avg_std = avg(std_scores)
          avg_turbo = avg(turbo_scores)
          delta = avg_turbo - avg_std

          # Average iteration scores for convergence info
          iter_scores = turbo_results
            |> Enum.map(& Map.get(&1, :iteration_scores, []))
            |> Enum.filter(& length(&1) > 0)
          avg_iters = if length(iter_scores) > 0 do
            n_iters = iter_scores |> Enum.map(&length/1) |> Enum.max()
            for i <- 0..(n_iters - 1) do
              vals = iter_scores |> Enum.map(&Enum.at(&1, i, 0.0))
              avg(vals) |> Float.round(0) |> trunc()
            end
            |> Enum.join("→")
          else
            "—"
          end

          snr_str = String.pad_leading("#{snr}", 4)
          std_link = String.pad_leading("#{pct(std_successes, n_trials)}%", 5)
          turbo_link = String.pad_leading("#{pct(turbo_successes, n_trials)}%", 5)
          std_s = String.pad_leading(fmtf(avg_std), 6)
          turbo_s = String.pad_leading(fmtf(avg_turbo), 6)
          delta_s = String.pad_leading("#{if delta >= 0, do: "+", else: ""}#{fmtf(delta)}", 6)

          IO.puts("   #{snr_str} dB  #{std_link}       #{turbo_link}       #{std_s}      #{turbo_s}     #{delta_s}   #{avg_iters}")

          # Return row data for summary
          %{snr: snr, std_link: pct(std_successes, n_trials), turbo_link: pct(turbo_successes, n_trials),
            std_score: avg_std, turbo_score: avg_turbo, delta_score: delta}
        end

        IO.puts("")
        {ch.name, snr_rows}
      end

      # Print pretty summary table
      for {ch_name, rows} <- all_channel_summaries do
        IO.puts("")
        IO.puts("  ┌─────────────────────────────────────────────────────────────────────┐")
        IO.puts("  │  #{String.pad_trailing("#{ch_name} Channel — Standard vs Turbo", 66)}│")
        IO.puts("  ├────────┬────────┬────────┬────────┬────────┬──────────┬─────────────┤")
        IO.puts("  │ SNR dB │  Std%  │ Turbo% │ ΔLink% │ StdScr │ TurboScr │   ΔScore    │")
        IO.puts("  ├────────┼────────┼────────┼────────┼────────┼──────────┼─────────────┤")

        for r <- rows do
          delta_link = r.turbo_link - r.std_link
          dl_str = if delta_link > 0, do: "+#{fmtf(delta_link)}", else: fmtf(delta_link)
          ds_str = if r.delta_score >= 0, do: "+#{fmtf(r.delta_score)}", else: fmtf(r.delta_score)

          # Highlight rows where turbo wins on link%
          marker = if delta_link > 0, do: " ▲", else: "  "

          IO.puts("  │ #{String.pad_leading("#{r.snr}", 4)}   │ #{String.pad_leading(fmtf(r.std_link), 5)} │ #{String.pad_leading(fmtf(r.turbo_link), 5)}  │ #{String.pad_leading(dl_str, 6)} │ #{String.pad_leading(fmtf(r.std_score), 5)}  │  #{String.pad_leading(fmtf(r.turbo_score), 5)}   │ #{String.pad_leading(ds_str, 6)}#{marker}  │")
        end

        # Compute 50% link threshold for each
        std_50 = find_threshold(rows, :std_link, 50)
        turbo_50 = find_threshold(rows, :turbo_link, 50)
        gain = if std_50 && turbo_50, do: fmtf(std_50 - turbo_50), else: "?"

        IO.puts("  ├────────┴────────┴────────┴────────┴────────┴──────────┴─────────────┤")
        IO.puts("  │  50% link threshold:  Std = #{String.pad_trailing(if(std_50, do: "#{fmtf(std_50)} dB", else: ">max"), 9)}  Turbo = #{String.pad_trailing(if(turbo_50, do: "#{fmtf(turbo_50)} dB", else: ">max"), 9)}          │")
        IO.puts("  │  Turbo coding gain:   ≈ #{String.pad_trailing("#{gain} dB", 42)}│")
        IO.puts("  └─────────────────────────────────────────────────────────────────────┘")
      end

      IO.puts("")
      :ok
    end
  end

  defp run_suite(n_trials, channel_types) do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║  LQA Score vs Channel Quality Characterization      ║")
    IO.puts("║  Trials per point: #{String.pad_leading("#{n_trials}", 3)}                               ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available. Start simnet first.")
      :error
    else
      all_results =
        for ch_type <- channel_types do
          ch = @channels[ch_type]
          snrs = @snr_points[ch_type]
          freq = @test_freqs[ch_type]

          IO.puts("─── #{ch.name} Channel ───")
          IO.puts("   SNR    Link%   LQA Score   Probe    Δpath     |LLR|    Decoded")
          IO.puts("   ────   ─────   ─────────   ─────    ─────     ─────    ───────")

          for snr <- snrs do
            results = run_trials(ch.delay_ms, ch.doppler_hz, snr, n_trials)

            successes = Enum.count(results, fn r -> r.decoded end)
            p_link = successes / n_trials

            # Aggregate LQA scores and metrics across trials
            scores = Enum.map(results, & &1.lqa_score)
            avg_score = avg(scores)

            probe_corrs = results |> Enum.map(& &1.probe_corr) |> Enum.filter(& &1 > 0)
            avg_probe = avg(probe_corrs)

            deltas = results |> Enum.map(& &1.path_metric_delta) |> Enum.filter(& &1 > 0)
            avg_delta = avg(deltas)

            llrs = results |> Enum.map(& &1.avg_llr) |> Enum.filter(& &1 > 0)
            avg_llr = avg(llrs)

            snr_str = String.pad_leading("#{snr}", 4)
            link_str = String.pad_leading("#{pct(successes, n_trials)}%", 5)
            score_str = String.pad_leading(fmtf(avg_score), 5)
            probe_str = String.pad_leading(fmtf(avg_probe), 5)
            delta_str = String.pad_leading(fmtf(avg_delta), 7)
            llr_str = String.pad_leading(fmtf(avg_llr), 5)

            IO.puts("   #{snr_str} dB  #{link_str}     #{score_str}     #{probe_str}  #{delta_str}     #{llr_str}    #{successes}/#{n_trials}")

            # Record successful decodes to LQA DB
            for r <- results, r.decoded do
              try do
                LQA.record_observation(@rig_id, 0x1234, freq, r.metrics,
                  frame_type: "sounding")
              rescue
                _ -> :ok
              end
            end

            %{
              channel: ch_type,
              snr_db: snr,
              p_link: p_link,
              avg_lqa_score: avg_score,
              avg_probe_corr: avg_probe,
              avg_delta: avg_delta,
              avg_llr: avg_llr,
              successes: successes,
              trials: n_trials
            }
          end
        end
        |> List.flatten()

      # Summary
      IO.puts("\n═══════════════════════════════════════════════════════")
      IO.puts("  Score Interpretation Guide:")
      IO.puts("  ─────────────────────────────")

      for ch_type <- channel_types do
        ch_results = Enum.filter(all_results, & &1.channel == ch_type)

        # Find the score threshold where p_link crosses 50% and 90%
        threshold_50 = find_threshold(ch_results, 0.50)
        threshold_90 = find_threshold(ch_results, 0.90)

        ch_name = @channels[ch_type].name
        IO.puts("  #{ch_name}:")
        if threshold_50, do: IO.puts("    50% link probability → LQA score ≈ #{fmtf(threshold_50)}")
        if threshold_90, do: IO.puts("    90% link probability → LQA score ≈ #{fmtf(threshold_90)}")
      end

      IO.puts("═══════════════════════════════════════════════════════\n")

      :ok
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Single Trial
  # ═══════════════════════════════════════════════════════════════════

  defp run_trials(delay_ms, doppler_hz, snr_db, n_trials) do
    for _ <- 1..n_trials do
      try do
        run_single_trial(delay_ms, doppler_hz, snr_db)
      rescue
        e ->
          Logger.debug("[LQA Channel] Trial crashed: #{inspect(e)}")
          %{decoded: false, lqa_score: 0.0, probe_corr: 0, path_metric_delta: 0.0,
            avg_llr: 0.0, metrics: %{}}
      end
    end
  end

  defp run_single_trial(delay_ms, doppler_hz, snr_db) do
    # Build and modulate a Deep WALE sounding frame
    {symbols, pdu_binary} = make_sounding_frame()

    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    # Apply channel impairment
    has_channel = delay_ms > 0 or doppler_hz > 0 or snr_db < 100
    impaired = if has_channel do
      channel_id = create_channel(delay_ms, doppler_hz, snr_db)
      channel_pad = List.duplicate(0, @channel_symbol_delay * 4 + 16)
      result = apply_channel(all_samples ++ channel_pad, channel_id)
      destroy_channel(channel_id)
      result
    else
      all_samples
    end

    # Demodulate to IQ
    has_multipath = delay_ms > 0 or doppler_hz > 0
    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod, impaired)

    total_delay = if has_channel, do: @filter_delay + @channel_symbol_delay, else: @filter_delay
    frame_iq = Enum.slice(iq_pairs, total_delay, length(symbols))

    # Extract probe correlation
    # The capture probe is the first 96 symbols
    capture_probe_iq = Enum.take(frame_iq, 96)
    probe_corr = compute_probe_correlation(capture_probe_iq)

    # Decode through the same path as the live receiver
    data_start = 96 + 576  # capture probe + preamble
    data_len = 6144         # 96 quadbits × 64 chips
    data_iq = Enum.slice(frame_iq, data_start, data_len)

    if length(data_iq) < data_len do
      %{decoded: false, lqa_score: 0.0, probe_corr: probe_corr,
        path_metric_delta: 0.0, avg_llr: 0.0, metrics: %{}}
    else
      decode_and_score(data_iq, pdu_binary, probe_corr, has_multipath)
    end
  end

  defp decode_and_score(data_iq, expected_pdu, probe_corr, _has_multipath) do
    # Always use the DFE path — it produces soft LLR output needed for
    # LQA scoring. On AWGN (no multipath), the equalizer is effectively
    # a no-op but we still get soft Viterbi metrics.
    case SoftWalsh.decode_iq_with_dfe(data_iq) do
      {:soft, soft_dibits, _scrambler, _hard_dibits} ->
        decode_soft_and_score(soft_dibits, expected_pdu, probe_corr)
      _ ->
        %{decoded: false, lqa_score: 0.0, probe_corr: probe_corr,
          path_metric_delta: 0.0, avg_llr: 0.0, metrics: %{}}
    end
  end

  defp decode_turbo_and_score(data_iq, expected_pdu, probe_corr) do
    case SoftWalsh.decode_iq_turbo(data_iq) do
      {:turbo, hard_bits, soft_dibit_llrs, iteration_scores, _scrambler} ->
        # Use BCJR hard bits for decode success
        data_bits = Enum.drop(hard_bits, -6)
        bytes = bits_to_bytes(data_bits)
        decoded = if length(bytes) >= byte_size(expected_pdu) do
          bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
        else
          false
        end

        first_score = List.first(iteration_scores) || 0.0
        last_score = List.last(iteration_scores) || 0.0
        turbo_gain = last_score - first_score

        # Map turbo LLR metrics to standard scoring scale.
        # Turbo produces LLRs in ±8.0 range; standard is ±4.0.
        #
        # Key insight: turbo LLR distribution is bimodal — converged blocks
        # push to ±8.0 (saturated) while unconverged blocks stay low. A simple
        # linear scaling undervalues this because the saturated blocks should
        # map to "perfect confidence" (4.0), not 4.0*0.5=2.0.
        #
        # Use a saturating per-LLR curve: 4.0 * (1 - exp(-|llr| / 3.0))
        # This maps: |llr|=1→1.1, 2→1.9, 3→2.5, 4→3.0, 6→3.6, 8→3.9
        # Preserves the quality distinction between marginal and good blocks
        # while correctly saturating near 4.0 for high-confidence turbo output.
        mapped_magnitudes = soft_dibit_llrs
          |> Enum.flat_map(fn {l1, l2} -> [abs(l1), abs(l2)] end)
          |> Enum.map(fn mag -> 4.0 * (1.0 - :math.exp(-mag / 3.0)) end)

        avg_llr = Enum.sum(mapped_magnitudes) / max(length(mapped_magnitudes), 1)

        # Derive path_metric_delta from the mapped avg_llr.
        # Standard Viterbi empirical correlation:
        #   avg_llr ~4.0 → delta ~14-16  (excellent)
        #   avg_llr ~3.5 → delta ~11     (good)
        #   avg_llr ~3.0 → delta ~8      (decent)
        #   avg_llr ~2.0 → delta ~3      (marginal)
        # Use quadratic: delta = (avg_llr / 4.0)^2 * 16.0
        # Gives: 4.0→16, 3.5→12.3, 3.0→9, 2.0→4, 1.0→1
        normalized = min(avg_llr / 4.0, 1.0)
        path_metric_delta = normalized * normalized * 16.0

        metrics = %{
          probe_corr: probe_corr,
          path_metric_delta: path_metric_delta,
          path_metric: last_score,
          avg_llr: avg_llr,
          min_llr: 0.0,
          decode_path: :turbo
        }

        lqa_score = LQA.score(metrics)

        %{
          decoded: decoded,
          lqa_score: lqa_score,
          probe_corr: probe_corr,
          path_metric_delta: path_metric_delta,
          avg_llr: avg_llr,
          metrics: metrics,
          iteration_scores: iteration_scores,
          turbo_gain: turbo_gain
        }

      _ ->
        %{decoded: false, lqa_score: 0.0, probe_corr: probe_corr,
          path_metric_delta: 0.0, avg_llr: 0.0, metrics: %{},
          iteration_scores: [], turbo_gain: 0.0}
    end
  end

  # Run a single trial returning both standard and turbo results.
  # Shares the same channel realization so the comparison is fair.
  defp run_single_trial_both(delay_ms, doppler_hz, snr_db) do
    {symbols, pdu_binary} = make_sounding_frame()

    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    has_channel = delay_ms > 0 or doppler_hz > 0 or snr_db < 100
    impaired = if has_channel do
      channel_id = create_channel(delay_ms, doppler_hz, snr_db)
      channel_pad = List.duplicate(0, @channel_symbol_delay * 4 + 16)
      result = apply_channel(all_samples ++ channel_pad, channel_id)
      destroy_channel(channel_id)
      result
    else
      all_samples
    end

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod, impaired)

    total_delay = if has_channel, do: @filter_delay + @channel_symbol_delay, else: @filter_delay
    frame_iq = Enum.slice(iq_pairs, total_delay, length(symbols))

    capture_probe_iq = Enum.take(frame_iq, 96)
    probe_corr = compute_probe_correlation(capture_probe_iq)

    data_start = 96 + 576
    data_len = 6144
    data_iq = Enum.slice(frame_iq, data_start, data_len)

    empty = %{decoded: false, lqa_score: 0.0, probe_corr: probe_corr,
              path_metric_delta: 0.0, avg_llr: 0.0, metrics: %{},
              iteration_scores: [], turbo_gain: 0.0}

    if length(data_iq) < data_len do
      {empty, empty}
    else
      std_result = decode_and_score(data_iq, pdu_binary, probe_corr, delay_ms > 0)
      turbo_result = decode_turbo_and_score(data_iq, pdu_binary, probe_corr)
      {std_result, turbo_result}
    end
  end

  defp decode_soft_and_score(soft_dibits, expected_pdu, probe_corr) do
    deinterleaved = Encoding.deinterleave_soft(soft_dibits, 12, 16)

    # Compute LLR statistics
    llr_magnitudes = soft_dibits |> Enum.flat_map(fn {l1, l2} -> [abs(l1), abs(l2)] end)
    avg_llr = Enum.sum(llr_magnitudes) / max(length(llr_magnitudes), 1)
    min_llr = Enum.min(llr_magnitudes, fn -> 0.0 end)

    # Viterbi decode
    case viterbi_decode_soft(deinterleaved) do
      {:ok, bits, terminal} ->
        bytes = bits_to_bytes(Enum.drop(bits, -6))
        decoded = if length(bytes) >= byte_size(expected_pdu) do
          bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
        else
          false
        end

        metrics = %{
          probe_corr: probe_corr,
          path_metric_delta: terminal.path_metric_delta,
          path_metric: terminal.path_metric,
          avg_llr: avg_llr,
          min_llr: min_llr,
          decode_path: :soft_iq
        }

        lqa_score = LQA.score(metrics)

        %{
          decoded: decoded,
          lqa_score: lqa_score,
          probe_corr: probe_corr,
          path_metric_delta: terminal.path_metric_delta,
          avg_llr: avg_llr,
          metrics: metrics
        }

      _ ->
        %{decoded: false, lqa_score: 0.0, probe_corr: probe_corr,
          path_metric_delta: 0.0, avg_llr: 0.0, metrics: %{}}
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Frame Assembly
  # ═══════════════════════════════════════════════════════════════════

  defp make_sounding_frame do
    pdu = %PDU.LsuStatus{
      caller_addr: 0x1234,
      status: 0
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

  # ═══════════════════════════════════════════════════════════════════
  # Probe Correlation
  # ═══════════════════════════════════════════════════════════════════

  defp compute_probe_correlation(probe_iq) when length(probe_iq) < 32, do: 0

  defp compute_probe_correlation(probe_iq) do
    # The demodulator outputs normalized IQ (~unit magnitude for clean signal).
    # We need a metric that maps to the 0-100 range that LQA.score expects.
    #
    # Use the consistency of IQ magnitudes as a proxy for channel quality:
    # clean channel → all magnitudes ≈ 1.0, low variance
    # noisy channel → scattered magnitudes, high variance
    #
    # Metric: 100 × (1 - coefficient_of_variation), clamped to [0, 100]
    magnitudes = Enum.map(probe_iq, fn {i, q} ->
      :math.sqrt(i * i + q * q)
    end)

    n = length(magnitudes)
    mean = Enum.sum(magnitudes) / n

    if mean < 0.01 do
      0
    else
      variance = Enum.reduce(magnitudes, 0.0, fn m, acc ->
        d = m - mean
        acc + d * d
      end) / n

      std_dev = :math.sqrt(variance)
      cv = std_dev / mean  # coefficient of variation

      # Clean signal: cv ≈ 0.05-0.1 → score 90-95
      # Marginal: cv ≈ 0.3-0.5 → score 50-70
      # Noise: cv > 1.0 → score 0
      score = (1.0 - cv) * 100.0
      min(max(score, 0.0), 100.0)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Channel Interface (via simnet RPC)
  # ═══════════════════════════════════════════════════════════════════

  defp create_channel(delay_ms, doppler_hz, snr_db) do
    node = SimnetClient.simnet_node()
    delay_samples = round(delay_ms * @sample_rate / 1000)
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

  defp destroy_channel(channel_id) do
    node = SimnetClient.simnet_node()
    :rpc.call(node, MinutemodemSimnet.Physics.Channel, :destroy, [channel_id])
  end

  defp apply_channel(samples_i16, channel_id) do
    f32_bin = Enum.into(samples_i16, <<>>, fn s ->
      <<(s / 32768.0)::native-float-32>>
    end)

    output_bin = rpc_process_block(channel_id, f32_bin)

    for <<f::native-float-32 <- output_bin>> do
      round(f * 32768.0) |> max(-32768) |> min(32767)
    end
  end

  defp rpc_process_block(channel_id, f32_binary) do
    node = SimnetClient.simnet_node()
    {:ok, output} = :rpc.call(node, MinutemodemSimnet.Physics.Channel, :process_block, [channel_id, f32_binary])
    output
  end

  # ═══════════════════════════════════════════════════════════════════
  # Soft Viterbi Decoder
  # ═══════════════════════════════════════════════════════════════════

  defp viterbi_decode_soft(soft_dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0.0, else: 100_000.0)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {final_metrics, final_paths} =
      Enum.reduce(soft_dibits, {initial_metrics, initial_paths}, fn soft_dibit, {metrics, paths} ->
        viterbi_step_soft(metrics, paths, soft_dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()

    state0_metric = Map.get(final_metrics, 0, 100_000.0)
    other_metrics = final_metrics
      |> Enum.reject(fn {s, _} -> s == 0 end)
      |> Enum.map(fn {_, m} -> m end)
    next_best = Enum.min(other_metrics, fn -> state0_metric end)

    terminal = %{
      path_metric: state0_metric,
      path_metric_delta: next_best - state0_metric
    }

    {:ok, decoded, terminal}
  end

  defp viterbi_step_soft(metrics, paths, {llr1, llr2}) do
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = next_state &&& 1
        prev_state = next_state >>> 1
        prev_state_alt = prev_state ||| 0x20

        {exp1, exp2} = expected_output(prev_state, input_bit)
        {exp1_alt, exp2_alt} = expected_output(prev_state_alt, input_bit)

        bm = soft_branch_metric(exp1, llr1) + soft_branch_metric(exp2, llr2)
        bm_alt = soft_branch_metric(exp1_alt, llr1) + soft_branch_metric(exp2_alt, llr2)

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

  defp soft_branch_metric(expected_bit, llr) do
    if expected_bit == 1, do: -llr, else: llr
  end

  defp expected_output(state, input_bit) do
    new_reg = (state <<< 1) ||| input_bit
    {parity(new_reg &&& @g1), parity(new_reg &&& @g2)}
  end

  defp parity(x), do: x |> Integer.digits(2) |> Enum.sum() |> rem(2)

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

  # ═══════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════

  defp find_threshold(results, target_p_link) do
    # Find the LQA score where p_link crosses the target
    # Linear interpolation between adjacent points
    sorted = Enum.sort_by(results, & &1.snr_db)
    pairs = Enum.zip(sorted, Enum.drop(sorted, 1))

    Enum.find_value(pairs, fn {lo, hi} ->
      if lo.p_link < target_p_link and hi.p_link >= target_p_link do
        # Interpolate
        frac = (target_p_link - lo.p_link) / max(hi.p_link - lo.p_link, 0.01)
        lo.avg_lqa_score + frac * (hi.avg_lqa_score - lo.avg_lqa_score)
      end
    end)
  end

  defp pct(n, total) when total > 0, do: Float.round(n / total * 100, 1)
  defp pct(_, _), do: 0.0

  defp avg([]), do: 0.0
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 2)

  defp fmtf(val) when is_float(val), do: :erlang.float_to_binary(Float.round(val, 1), decimals: 1)
  defp fmtf(val) when is_integer(val), do: to_string(val)
  defp fmtf(_), do: "—"

  # Find SNR where link% first reaches the threshold via linear interpolation
  defp find_threshold(rows, key, threshold) do
    pairs = Enum.map(rows, fn r -> {r.snr, Map.get(r, key, 0)} end)
    Enum.zip(Enum.drop(pairs, -1), Enum.drop(pairs, 1))
    |> Enum.find_value(fn {{s1, v1}, {s2, v2}} ->
      if v1 < threshold and v2 >= threshold do
        # Linear interpolation
        frac = (threshold - v1) / max(v2 - v1, 0.01)
        s1 + frac * (s2 - s1)
      end
    end)
  end

  defp format_freq(freq_hz) when freq_hz >= 1_000_000 do
    "#{Float.round(freq_hz / 1_000_000, 3)} MHz"
  end
  defp format_freq(freq_hz), do: "#{freq_hz} Hz"
end
