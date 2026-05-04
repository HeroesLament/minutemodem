defmodule MinuteModemCore.ALE.ComplianceTest do
  @moduledoc """
  MIL-STD-188-141D Table G-III Compliance Test: Deep WALE Linking Probability.

  Tests the full pipeline: PDU → encode → modulate → channel → demodulate → decode
  against the standard channel conditions (AWGN, Good, Poor) at specified SNRs.

  Channel definitions (ITU-R F.1487 / CCIR Rec. 520):
    AWGN:  1 path, no fading, noise only
    Good:  2 paths, 0.5 ms delay, 0.5 Hz Doppler, Rayleigh fading
    Poor:  2 paths, 2.0 ms delay, 1.0 Hz Doppler, Rayleigh fading

  Run:  MinuteModemCore.ALE.ComplianceTest.run()
        MinuteModemCore.ALE.ComplianceTest.run(:quick)     # 20 trials (fast)
        MinuteModemCore.ALE.ComplianceTest.run(:full)      # 100 trials (standard)
        MinuteModemCore.ALE.ComplianceTest.run(:awgn)      # AWGN only
        MinuteModemCore.ALE.ComplianceTest.run(:good)      # Good channel only
        MinuteModemCore.ALE.ComplianceTest.run(:poor)      # Poor channel only
  """

  require Logger

  alias MinuteModemCore.ALE.{PDU, Waveform}
  alias MinuteModemCore.ALE.Waveform.DeepWale
  alias MinuteModemCore.ALE.Waveform.SoftWalsh
  alias MinuteModemCore.ALE.Encoding
  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Rig.SimnetClient

  import Bitwise

  @sample_rate 9600
  @filter_delay 12
  @channel_symbol_delay 16

  # Viterbi decoder constants
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  # ═══════════════════════════════════════════════════════════════════════════
  # Channel Definitions
  # ═══════════════════════════════════════════════════════════════════════════

  @channels %{
    awgn: %{name: "AWGN", delay_ms: 0.0, doppler_hz: 0.0},
    good: %{name: "Good", delay_ms: 0.5, doppler_hz: 0.5},
    poor: %{name: "Poor", delay_ms: 2.0, doppler_hz: 1.0}
  }

  # Table G-III: Required linking probability at each SNR
  # {snr_db, required_probability}
  @table_g_iii %{
    awgn: [
      {-6,  0.95},
      {-7,  0.85},
      {-8,  0.50},
      {-9,  0.25}
    ],
    good: [
      {2,   0.95},
      {-2,  0.85},
      {-5,  0.50},
      {-7,  0.25}
    ],
    poor: [
      {4,   0.95},
      {1,   0.85},
      {-2,  0.50},
      {-5,  0.25}
    ]
  }

  # Extended SNR sweep for characterization (beyond Table G-III)
  @extended_snrs %{
    awgn: [-12, -10, -9, -8, -7, -6, -5, -3, 0, 3, 6, 10, 15],
    good: [-10, -7, -5, -2, 0, 2, 4, 6, 10, 15],
    poor: [-7, -5, -2, 0, 1, 2, 4, 6, 10, 15]
  }

  # ═══════════════════════════════════════════════════════════════════════════
  # Entry Points
  # ═══════════════════════════════════════════════════════════════════════════

  def run(mode \\ :quick)

  def run(:quick), do: run_suite(20, [:awgn, :good, :poor], :compliance)
  def run(:full), do: run_suite(100, [:awgn, :good, :poor], :compliance)
  def run(:extended), do: run_suite(200, [:awgn, :good, :poor], :compliance)
  def run(:awgn), do: run_suite(20, [:awgn], :compliance)
  def run(:good), do: run_suite(20, [:good], :compliance)
  def run(:poor), do: run_suite(20, [:poor], :compliance)
  def run(:sweep), do: run_suite(20, [:awgn, :good, :poor], :sweep)

  @doc """
  Run a single test point: one channel type, one SNR, N trials.
  Returns {successes, trials}.
  """
  def test_point(channel_type, snr_db, n_trials \\ 20) do
    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available")
      {0, 0}
    else
      ch = @channels[channel_type]
      results = run_trials(ch.delay_ms, ch.doppler_hz, snr_db, n_trials)
      successes = Enum.count(results, fn {pass, _} -> pass end)
      IO.puts("#{ch.name} @ #{snr_db} dB: #{successes}/#{n_trials} (#{pct(successes, n_trials)}%)")
      {successes, n_trials}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Test Suite Runner
  # ═══════════════════════════════════════════════════════════════════════════

  defp run_suite(n_trials, channel_types, mode) do
    IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
    IO.puts("║  MIL-STD-188-141D Table G-III: Deep WALE Compliance Test   ║")
    IO.puts("║  Trials per point: #{String.pad_leading("#{n_trials}", 3)}                                      ║")
    IO.puts("╚══════════════════════════════════════════════════════════════╝\n")

    unless SimnetClient.available?() do
      IO.puts("ERROR: simnet node not available. Start simnet first.")
      :error
    else
      all_results =
        for ch_type <- channel_types do
          ch = @channels[ch_type]
          snrs = case mode do
            :compliance -> @table_g_iii[ch_type] |> Enum.map(fn {snr, _} -> snr end)
            :sweep -> @extended_snrs[ch_type]
          end

          IO.puts("─── #{ch.name} Channel (delay=#{ch.delay_ms}ms, doppler=#{ch.doppler_hz}Hz) ───")

          point_results =
            for snr <- snrs do
              t_start = System.monotonic_time(:millisecond)
              results = run_trials(ch.delay_ms, ch.doppler_hz, snr, n_trials)
              elapsed = System.monotonic_time(:millisecond) - t_start

              successes = Enum.count(results, fn {pass, _} -> pass end)
              p_link = successes / n_trials

              {status, required} = case mode do
                :compliance ->
                  req = @table_g_iii[ch_type]
                        |> Enum.find(fn {s, _} -> s == snr end)
                        |> elem(1)
                  status = if p_link >= req, do: "✓", else: "✗"
                  {status, req}
                :sweep ->
                  {"·", nil}
              end

              snr_str = String.pad_leading("#{snr}", 4)
              pct_str = String.pad_leading("#{pct(successes, n_trials)}", 5)

              if required do
                req_str = "#{round(required * 100)}%"
                IO.puts("   SNR #{snr_str} dB: #{pct_str}% (#{successes}/#{n_trials}) need #{req_str}  #{status}  [#{elapsed}ms]")
              else
                IO.puts("   SNR #{snr_str} dB: #{pct_str}% (#{successes}/#{n_trials})  [#{elapsed}ms]")
              end

              all_metrics = results |> Enum.map(fn {_, m} -> m end) |> Enum.filter(fn m -> map_size(m) > 0 end)
              if length(all_metrics) > 0 do
                avg_delta = all_metrics |> Enum.map(& Map.get(&1, :viterbi_delta, 0.0)) |> avg()
                avg_agree = all_metrics |> Enum.map(& Map.get(&1, :avg_agreement, 0.0)) |> avg()
                avg_llr_val = all_metrics |> Enum.map(& Map.get(&1, :avg_llr, 0.0)) |> avg()
                soft_saved = all_metrics |> Enum.count(& Map.get(&1, :ab_status) == :soft_saved)
                soft_hurt = all_metrics |> Enum.count(& Map.get(&1, :ab_status) == :soft_hurt)
                avg_low_conf = all_metrics |> Enum.map(& Map.get(&1, :low_conf_steps, 0)) |> avg()

                ab_str = cond do
                  soft_saved > 0 and soft_hurt > 0 -> "soft +#{soft_saved}/-#{soft_hurt}"
                  soft_saved > 0 -> "soft +#{soft_saved}"
                  soft_hurt > 0 -> "soft -#{soft_hurt}"
                  true -> ""
                end

                IO.puts("          ╰─ Δpath=#{fmtf(avg_delta)} agree=#{fmtf(avg_agree)} |LLR|=#{fmtf(avg_llr_val)} low_conf=#{fmtf(avg_low_conf)} #{ab_str}")
              end

              %{
                channel: ch_type,
                snr_db: snr,
                successes: successes,
                trials: n_trials,
                p_link: p_link,
                required: required,
                pass: if(required, do: p_link >= required, else: nil),
                elapsed_ms: elapsed
              }
            end

          IO.puts("")
          point_results
        end
        |> List.flatten()

      # Summary
      compliance_results = Enum.filter(all_results, & &1.required)
      passed = Enum.count(compliance_results, & &1.pass)
      failed = Enum.count(compliance_results, &(not &1.pass))

      IO.puts("═══════════════════════════════════════════════════════════════")
      if length(compliance_results) > 0 do
        IO.puts("  Compliance: #{passed}/#{passed + failed} test points passed")

        if failed > 0 do
          IO.puts("  FAILURES:")
          for r <- Enum.filter(compliance_results, &(not &1.pass)) do
            ch = @channels[r.channel]
            IO.puts("    #{ch.name} @ #{r.snr_db} dB: #{pct(r.successes, r.trials)}% < #{round(r.required * 100)}% required")
          end
        end
      end
      IO.puts("═══════════════════════════════════════════════════════════════\n")

      if failed == 0, do: :pass, else: {:fail, failed, all_results}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Single Trial
  # ═══════════════════════════════════════════════════════════════════════════

  defp run_trials(delay_ms, doppler_hz, snr_db, n_trials) do
    for trial <- 1..n_trials do
      try do
        run_single_trial(delay_ms, doppler_hz, snr_db, trial)
      rescue
        e ->
          Logger.warning("[Compliance] Trial #{trial} crashed: #{inspect(e)}")
          {false, %{}}
      end
    end
  end

  defp run_single_trial(delay_ms, doppler_hz, snr_db, trial_num) do
    {symbols, pdu_binary} = make_frame()

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

    has_multipath = delay_ms > 0 or doppler_hz > 0

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    PhyModem.unified_demod_set_block_size(demod, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod, impaired)

    total_delay = if has_channel, do: @filter_delay + @channel_symbol_delay, else: @filter_delay
    frame_iq = Enum.slice(iq_pairs, total_delay, length(symbols))

    if has_multipath do
      decode_frame_soft_dfe(frame_iq, pdu_binary)
    else
      decode_frame_soft(frame_iq, pdu_binary)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Frame Assembly / Decode
  # ═══════════════════════════════════════════════════════════════════════════

  defp make_frame do
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

  @compliance_rig_id "compliance-test"

  defp decode_frame(rx_symbols, expected_pdu) do
    data_start = 96 + 576   # capture probe + preamble
    data_len = 6144          # 96 quadbits × 64 chips

    data_symbols = Enum.slice(rx_symbols, data_start, data_len)

    if length(data_symbols) < data_len do
      false
    else
      # Suppress noisy per-block logging during bulk trials
      {decoded_dibits, _} = DeepWale.decode_data(data_symbols)
      deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

      case viterbi_decode(deinterleaved) do
        {:ok, bits, terminal} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          pass = if length(bytes) >= byte_size(expected_pdu) do
            decoded_bin = bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary()
            decoded_bin == expected_pdu
          else
            false
          end

          :telemetry.execute(
            [:minutemodem, :ale, :decode],
            Map.merge(terminal, %{symbol_count: data_len}),
            %{rig_id: @compliance_rig_id, waveform: :deep, decode_path: :hard,
              result: if(pass, do: :ok, else: :error), error_reason: nil}
          )

          pass

        {:error, _} ->
          false
      end
    end
  end

  defp decode_frame_soft(frame_iq, expected_pdu) do
    data_start = 96 + 576
    data_len = 6144
    data_iq = Enum.slice(frame_iq, data_start, data_len)

    if length(data_iq) < data_len do
      {false, %{}}
    else
      {decoded_dibits, _} = SoftWalsh.decode_iq(data_iq)
      deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)

      case viterbi_decode(deinterleaved) do
        {:ok, bits, terminal} ->
          bytes = bits_to_bytes(Enum.drop(bits, -6))
          pass = if length(bytes) >= byte_size(expected_pdu) do
            bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
          else
            false
          end

          :telemetry.execute(
            [:minutemodem, :ale, :decode],
            Map.merge(terminal, %{symbol_count: data_len}),
            %{rig_id: @compliance_rig_id, waveform: :deep, decode_path: :soft_iq,
              result: if(pass, do: :ok, else: :error), error_reason: nil}
          )

          {pass, %{}}

        {:error, _} ->
          {false, %{}}
      end
    end
  end

  defp decode_frame_soft_dfe(frame_iq, expected_pdu) do
    data_start = 96 + 576
    data_len = 6144
    data_iq = Enum.slice(frame_iq, data_start, data_len)

    if length(data_iq) < data_len do
      {false, %{}}
    else
      case SoftWalsh.decode_iq_with_dfe(data_iq) do
        {:soft, soft_dibits, _scrambler, hard_dibits} ->
          deinterleaved_soft = Encoding.deinterleave_soft(soft_dibits, 12, 16)
          deinterleaved_hard = Encoding.deinterleave(hard_dibits, 12, 16)

          llr_magnitudes = soft_dibits |> Enum.flat_map(fn {l1, l2} -> [abs(l1), abs(l2)] end)
          avg_llr = Enum.sum(llr_magnitudes) / max(length(llr_magnitudes), 1)
          min_llr = Enum.min(llr_magnitudes, fn -> 0.0 end)

          # Use diagnostic Viterbi for per-step agreement (compliance-specific depth)
          {soft_result, viterbi_metrics} = case viterbi_decode_soft_diagnostic(deinterleaved_soft) do
            {:ok, bits, step_diag, terminal} ->
              bytes = bits_to_bytes(Enum.drop(bits, -6))
              pass = if length(bytes) >= byte_size(expected_pdu) do
                bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
              else
                false
              end
              avg_agreement = step_diag |> Enum.map(& &1.agreement) |> Enum.sum() |> then(& &1 / max(length(step_diag), 1))
              low_conf = step_diag |> Enum.count(& &1.agreement < 0.75)
              {pass, %{
                viterbi_delta: terminal.path_metric_delta,
                viterbi_final: terminal.final_metric,
                avg_agreement: avg_agreement,
                low_conf_steps: low_conf
              }}
            {:error, _} -> {false, %{viterbi_delta: 0.0, viterbi_final: 0.0, avg_agreement: 0.0, low_conf_steps: 0}}
          end

          # Emit telemetry in the same shape as the live receiver
          :telemetry.execute(
            [:minutemodem, :ale, :decode],
            %{
              path_metric: Map.get(viterbi_metrics, :viterbi_final, 0.0),
              path_metric_delta: Map.get(viterbi_metrics, :viterbi_delta, 0.0),
              symbol_count: data_len,
              avg_llr: avg_llr,
              min_llr: min_llr
            },
            %{rig_id: @compliance_rig_id, waveform: :deep, decode_path: :soft_iq,
              result: if(soft_result, do: :ok, else: :error), error_reason: nil}
          )

          # Hard A/B comparison (compliance-specific)
          hard_result = case viterbi_decode(deinterleaved_hard) do
            {:ok, bits, _terminal} ->
              bytes = bits_to_bytes(Enum.drop(bits, -6))
              if length(bytes) >= byte_size(expected_pdu) do
                bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
              else
                false
              end
            {:error, _} -> false
          end

          ab_status = cond do
            soft_result and not hard_result -> :soft_saved
            not soft_result and hard_result -> :soft_hurt
            true -> :agree
          end

          metrics = Map.merge(viterbi_metrics, %{
            avg_llr: avg_llr,
            min_llr: min_llr,
            hard_pass: hard_result,
            ab_status: ab_status
          })

          {soft_result, metrics}

        {decoded_dibits, _scrambler} ->
          deinterleaved = Encoding.deinterleave(decoded_dibits, 12, 16)
          case viterbi_decode(deinterleaved) do
            {:ok, bits, terminal} ->
              bytes = bits_to_bytes(Enum.drop(bits, -6))
              pass = if length(bytes) >= byte_size(expected_pdu) do
                bytes |> Enum.take(byte_size(expected_pdu)) |> :erlang.list_to_binary() == expected_pdu
              else
                false
              end

              :telemetry.execute(
                [:minutemodem, :ale, :decode],
                Map.merge(terminal, %{symbol_count: data_len}),
                %{rig_id: @compliance_rig_id, waveform: :deep, decode_path: :hard,
                  result: if(pass, do: :ok, else: :error), error_reason: nil}
              )

              {pass, %{}}
            {:error, _} -> {false, %{}}
          end
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Channel Interface
  # ═══════════════════════════════════════════════════════════════════════════

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

  # ═══════════════════════════════════════════════════════════════════════════
  # Viterbi Decoder
  # ═══════════════════════════════════════════════════════════════════════════

  defp viterbi_decode(dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    terminal = extract_terminal_metrics(final_metrics)
    {:ok, decoded, terminal}
  end

  # ── Soft Viterbi ──
  # Branch metric uses Euclidean distance with LLR soft values.
  # LLR > 0 means bit=1 likely, LLR < 0 means bit=0 likely.
  # Expected bit 0 → contribution = -LLR (reward for negative LLR)
  # Expected bit 1 → contribution = +LLR (reward for positive LLR)
  # Branch metric = -Σ(expected * LLR) — lower is better (like Hamming).

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
    terminal = extract_terminal_metrics(final_metrics)
    {:ok, decoded, terminal}
  end

  @doc """
  Instrumented soft Viterbi: returns decoded bits + per-step diagnostics.

  Diagnostics per step:
    - metric_spread: max - min of all 64 state metrics (trellis confidence)
    - best_metric: lowest path metric (best path cost so far)
    - survivor_agreement: fraction of states whose path agrees on the
      bit decoded `convergence_depth` steps ago (0.5 = no consensus, 1.0 = all agree)

  Terminal diagnostics:
    - path_metric_delta: gap between state-0 metric and next-best state
    - final_metric: state-0 path metric at termination
  """
  def viterbi_decode_soft_diagnostic(soft_dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0.0, else: 100_000.0)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    convergence_depth = 24

    {final_metrics, final_paths, step_diagnostics} =
      Enum.reduce(
        Enum.with_index(soft_dibits),
        {initial_metrics, initial_paths, []},
        fn {soft_dibit, step_idx}, {metrics, paths, diag_acc} ->
          {new_metrics, new_paths} = viterbi_step_soft(metrics, paths, soft_dibit)

          # Collect per-step diagnostics
          all_metrics = Map.values(new_metrics)
          best = Enum.min(all_metrics)
          worst = all_metrics |> Enum.reject(&(&1 >= 99_000.0)) |> Enum.max(fn -> best end)
          spread = worst - best

          # Survivor agreement: look back convergence_depth steps
          agreement = if step_idx >= convergence_depth do
            # For each state's path, get the bit at position convergence_depth from end
            bits_at_depth = Map.values(new_paths)
              |> Enum.map(fn path ->
                # path is reversed (newest first), so position convergence_depth
                Enum.at(path, convergence_depth, -1)
              end)
              |> Enum.reject(&(&1 == -1))

            if length(bits_at_depth) > 0 do
              ones = Enum.count(bits_at_depth, &(&1 == 1))
              total = length(bits_at_depth)
              max(ones, total - ones) / total
            else
              0.5
            end
          else
            0.5
          end

          step_diag = %{
            step: step_idx,
            spread: spread,
            best_metric: best,
            agreement: agreement,
          }

          {new_metrics, new_paths, [step_diag | diag_acc]}
        end
      )

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()

    # Terminal diagnostics
    state0_metric = Map.get(final_metrics, 0, 100_000.0)
    other_metrics = final_metrics
      |> Enum.reject(fn {s, _} -> s == 0 end)
      |> Enum.map(fn {_, m} -> m end)
    next_best = Enum.min(other_metrics, fn -> state0_metric end)
    path_metric_delta = next_best - state0_metric

    terminal = %{
      final_metric: state0_metric,
      path_metric_delta: path_metric_delta,
    }

    {:ok, decoded, Enum.reverse(step_diagnostics), terminal}
  end

  defp viterbi_step_soft(metrics, paths, {llr1, llr2}) do
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = next_state &&& 1
        prev_state = next_state >>> 1
        prev_state_alt = prev_state ||| 0x20

        {exp1, exp2} = expected_output(prev_state, input_bit)
        {exp1_alt, exp2_alt} = expected_output(prev_state_alt, input_bit)

        # Soft branch metric: sum of -sign(expected) * LLR
        # If expected=1, we want LLR positive → cost = -LLR
        # If expected=0, we want LLR negative → cost = +LLR
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

  # Soft branch metric: cost of observing LLR when expected bit is exp (0 or 1)
  # Lower cost = better match
  defp soft_branch_metric(expected_bit, llr) do
    # If expected=1: cost = -llr (reward positive LLR)
    # If expected=0: cost = +llr (reward negative LLR)
    if expected_bit == 1, do: -llr, else: llr
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp extract_terminal_metrics(final_metrics) do
    state0_metric = Map.get(final_metrics, 0, 0)
    next_best = final_metrics
      |> Enum.reject(fn {s, _} -> s == 0 end)
      |> Enum.map(fn {_, m} -> m end)
      |> Enum.min(fn -> state0_metric end)

    %{
      path_metric: state0_metric,
      path_metric_delta: next_best - state0_metric
    }
  end

  defp pct(n, total) when total > 0, do: Float.round(n / total * 100, 1)
  defp pct(_, _), do: 0.0

  defp avg([]), do: 0.0
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 2)

  defp fmtf(val) when is_float(val), do: Float.round(val, 2) |> to_string()
  defp fmtf(val) when is_integer(val), do: to_string(val)
  defp fmtf(val), do: inspect(val)
end
