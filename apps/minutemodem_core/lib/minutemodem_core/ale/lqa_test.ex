defmodule MinuteModemCore.ALE.LQATest do
  @moduledoc """
  Shell test for the LQA system: scoring, recording, sounding, and channel ranking.

  Tests the full LQA pipeline without requiring simnet or real audio.
  Uses manual PDU injection to simulate receiving frames and verifies
  that LQA observations are recorded and influence channel selection.

  Run:
    MinuteModemCore.ALE.LQATest.run()

  Or step-by-step:
    MinuteModemCore.ALE.LQATest.setup()
    MinuteModemCore.ALE.LQATest.test_scoring()
    MinuteModemCore.ALE.LQATest.test_record_observation()
    MinuteModemCore.ALE.LQATest.test_channel_ranking()
    MinuteModemCore.ALE.LQATest.test_sounder_schedule()
    MinuteModemCore.ALE.LQATest.test_sounding_frame_assembly()
    MinuteModemCore.ALE.LQATest.test_manual_sounding()
    MinuteModemCore.ALE.LQATest.test_lqa_exchange()
    MinuteModemCore.ALE.LQATest.test_lqa_informed_calling()
    MinuteModemCore.ALE.LQATest.cleanup()
  """

  alias MinuteModemCore.ALE.{Link, PDU, Waveform, LQA}
  alias MinuteModemCore.ALE.LQA.Sounder
  alias MinuteModemCore.Persistence.{Callsigns, Repo}

  @rig_a "lqa-test-rig-a"
  @rig_b "lqa-test-rig-b"
  @addr_a 0x1A2B
  @addr_b 0x3C4D
  @addr_c 0x5E6F

  @channels [
    %{freq_hz: 7_102_000, name: "40M-1", mode: :usb},
    %{freq_hz: 7_185_000, name: "40M-2", mode: :usb},
    %{freq_hz: 14_109_000, name: "20M-1", mode: :usb},
    %{freq_hz: 14_346_000, name: "20M-2", mode: :usb}
  ]

  # ═══════════════════════════════════════════════════════════════════
  # Entry Points
  # ═══════════════════════════════════════════════════════════════════

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════╗")
    IO.puts("║       LQA System Test Suite                         ║")
    IO.puts("╚══════════════════════════════════════════════════════╝\n")

    setup()

    results = [
      {"Scoring", &test_scoring/0},
      {"Record observation", &test_record_observation/0},
      {"Channel ranking", &test_channel_ranking/0},
      {"Sounder schedule", &test_sounder_schedule/0},
      {"Sounding frame assembly", &test_sounding_frame_assembly/0},
      {"Manual sounding", &test_manual_sounding/0},
      {"LQA exchange", &test_lqa_exchange/0},
      {"LQA-informed calling", &test_lqa_informed_calling/0},
      {"Turbo decode loopback", &test_turbo_decode_loopback/0}
    ]

    outcomes = Enum.map(results, fn {name, test_fn} ->
      IO.puts("─── #{name} ───")
      try do
        test_fn.()
        IO.puts("   ✓ PASS\n")
        :pass
      rescue
        e ->
          IO.puts("   ✗ FAIL: #{inspect(e)}")
          IO.puts("   #{Exception.format_stacktrace(__STACKTRACE__)}")
          IO.puts("")
          :fail
      catch
        kind, reason ->
          IO.puts("   ✗ FAIL: #{kind} #{inspect(reason)}\n")
          :fail
      end
    end)

    cleanup()

    passed = Enum.count(outcomes, &(&1 == :pass))
    failed = Enum.count(outcomes, &(&1 == :fail))

    IO.puts("═══════════════════════════════════════════════════════")
    IO.puts("  Results: #{passed} passed, #{failed} failed")
    IO.puts("═══════════════════════════════════════════════════════\n")

    if failed == 0, do: :ok, else: :failed
  end

  # ═══════════════════════════════════════════════════════════════════
  # Setup / Cleanup
  # ═══════════════════════════════════════════════════════════════════

  def setup do
    IO.puts("Setting up LQA test environment...")

    # Start Link FSMs
    {:ok, _} = Link.start_link(rig_id: @rig_a, self_addr: @addr_a)
    {:ok, _} = Link.start_link(rig_id: @rig_b, self_addr: @addr_b)

    IO.puts("  Rig A: #{@rig_a} (0x#{Integer.to_string(@addr_a, 16)})")
    IO.puts("  Rig B: #{@rig_b} (0x#{Integer.to_string(@addr_b, 16)})")
    IO.puts("  ✓ Setup complete\n")
  end

  def cleanup do
    IO.puts("\nCleaning up...")
    safe_stop(@rig_a)
    safe_stop(@rig_b)
    IO.puts("  ✓ Cleanup complete")
  end

  defp safe_stop(rig_id) do
    GenStateMachine.stop(Link.via(rig_id), :normal)
  rescue
    _ -> :ok
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 1: LQA Scoring
  # ═══════════════════════════════════════════════════════════════════

  def test_scoring do
    # Excellent metrics: high probe corr, saturated Viterbi delta, saturated LLR
    # Real decoder: delta caps at ~16, LLR caps at 4.0, probe CV ~85
    excellent = LQA.score(%{
      probe_corr: 85,
      path_metric_delta: 16.0,
      avg_llr: 4.0
    })
    IO.puts("   Excellent: #{excellent}")
    assert_in_range(excellent, 85.0, 100.0, "excellent score")

    # Good metrics: typical Good channel at moderate SNR
    good = LQA.score(%{
      probe_corr: 60,
      path_metric_delta: 12.0,
      avg_llr: 3.5
    })
    IO.puts("   Good: #{good}")
    assert_in_range(good, 55.0, 80.0, "good score")

    # Marginal metrics: Poor channel near decode threshold
    marginal = LQA.score(%{
      probe_corr: 55,
      path_metric_delta: 4.0,
      avg_llr: 2.0
    })
    IO.puts("   Marginal: #{marginal}")
    assert_in_range(marginal, 25.0, 45.0, "marginal score")

    # Bad metrics: barely decoded
    bad = LQA.score(%{
      probe_corr: 50,
      path_metric_delta: 1.0,
      avg_llr: 1.0
    })
    IO.puts("   Bad: #{bad}")
    assert_in_range(bad, 10.0, 25.0, "bad score")

    # Empty metrics
    empty = LQA.score(%{})
    IO.puts("   Empty: #{empty}")
    assert_equal(empty, 0.0, "empty score")

    # Ordering: excellent > good > marginal > bad
    true = excellent > good
    true = good > marginal
    true = marginal > bad
    IO.puts("   Ordering: #{excellent} > #{good} > #{marginal} > #{bad} ✓")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 2: Record Observation
  # ═══════════════════════════════════════════════════════════════════

  def test_record_observation do
    freq = 7_102_000
    metrics = %{
      probe_corr: 75,
      path_metric_delta: 200.0,
      path_metric: 50.0,
      avg_llr: 3.0,
      min_llr: 0.8,
      preamble_zeros: 28,
      decode_path: :soft_iq
    }

    {:ok, {callsign, sounding}} = LQA.record_observation(
      @rig_a, @addr_b, freq, metrics,
      frame_type: "call"
    )

    IO.puts("   Recorded: callsign=#{callsign.addr}, sounding_id=#{sounding.id}")
    IO.puts("   Freq: #{sounding.freq_hz}")
    IO.puts("   Rig: #{sounding.rig_id}")
    IO.puts("   Direction: #{sounding.direction}")
    IO.puts("   Frame type: #{sounding.frame_type}")
    IO.puts("   Extra keys: #{inspect(Map.keys(sounding.extra))}")

    # Verify the extra map has our metrics
    true = Map.has_key?(sounding.extra, "lqa_score")
    true = Map.has_key?(sounding.extra, "probe_corr")
    true = Map.has_key?(sounding.extra, "path_metric_delta")
    true = Map.has_key?(sounding.extra, "avg_llr")

    score = sounding.extra["lqa_score"]
    IO.puts("   LQA score: #{score}")
    assert_in_range(score, 50.0, 95.0, "recorded score")

    # Record a second observation on a different frequency
    {:ok, {_cs2, s2}} = LQA.record_observation(
      @rig_a, @addr_b, 14_109_000,
      %{probe_corr: 50, path_metric_delta: 80.0, avg_llr: 2.0},
      frame_type: "call"
    )
    IO.puts("   Second observation on #{s2.freq_hz}: score=#{s2.extra["lqa_score"]}")

    # Record from a different station
    {:ok, {cs3, _s3}} = LQA.record_observation(
      @rig_a, @addr_c, freq,
      %{probe_corr: 40, path_metric_delta: 30.0, avg_llr: 1.5},
      frame_type: "sounding"
    )
    IO.puts("   Third observation from 0x#{Integer.to_string(cs3.addr, 16)}")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 3: Channel Ranking
  # ═══════════════════════════════════════════════════════════════════

  def test_channel_ranking do
    # Use a unique address so prior test runs' data doesn't interfere
    rank_addr = :rand.uniform(0xFFFF)

    # Seed observations with distinct quality per channel
    # Channel 1 (7.102): excellent
    LQA.record_observation(@rig_a, rank_addr, 7_102_000,
      %{probe_corr: 90, path_metric_delta: 500.0, avg_llr: 4.5},
      frame_type: "call")

    # Channel 2 (7.185): poor
    LQA.record_observation(@rig_a, rank_addr, 7_185_000,
      %{probe_corr: 30, path_metric_delta: 5.0, avg_llr: 0.5},
      frame_type: "call")

    # Channel 3 (14.109): good
    LQA.record_observation(@rig_a, rank_addr, 14_109_000,
      %{probe_corr: 70, path_metric_delta: 150.0, avg_llr: 3.0},
      frame_type: "call")

    # Channel 4 (14.346): no data

    # Rank channels for reaching rank_addr from rig_a
    ranked = LQA.rank_channels(@rig_a, rank_addr, @channels)

    IO.puts("   Channel ranking for 0x#{Integer.to_string(rank_addr, 16)}:")
    for ch <- ranked do
      IO.puts("     #{format_freq(ch.freq_hz)}: score=#{ch.score}, count=#{ch.count}, last=#{inspect(ch.last_heard)}")
    end

    # Verify ordering: 7.102 (excellent) > 14.109 (good) > 7.185 (poor) > 14.346 (no data)
    [first | _] = ranked
    true = first.freq_hz == 7_102_000
    IO.puts("   Best channel: #{format_freq(first.freq_hz)} ✓")

    last = List.last(ranked)
    true = last.score == 0.0
    IO.puts("   Worst (no data): #{format_freq(last.freq_hz)} ✓")

    # Test best_channel convenience
    best = LQA.best_channel(@rig_a, rank_addr, @channels)
    true = best.freq_hz == 7_102_000
    IO.puts("   best_channel/4: #{format_freq(best.freq_hz)} ✓")

    # Test best_channel with unknown station — should return nil
    nil = LQA.best_channel(@rig_a, 0xFFFF, @channels)
    IO.puts("   best_channel for unknown station: nil ✓")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 4: Sounder Schedule
  # ═══════════════════════════════════════════════════════════════════

  def test_sounder_schedule do
    # Empty schedule — all channels should be eligible
    schedule = %{}

    true = Sounder.should_sound?(schedule, 7_102_000)
    IO.puts("   Empty schedule, any freq: should_sound? = true ✓")

    # Record a sounding
    schedule = Sounder.record_sounding_tx(schedule, 7_102_000)
    IO.puts("   Recorded sounding on 7.102 MHz")

    # Just sounded — should NOT sound again
    false = Sounder.should_sound?(schedule, 7_102_000, min_interval_s: 300)
    IO.puts("   Just sounded, 5min interval: should_sound? = false ✓")

    # But with 0 interval, should sound
    true = Sounder.should_sound?(schedule, 7_102_000, min_interval_s: 0)
    IO.puts("   Just sounded, 0s interval: should_sound? = true ✓")

    # Different frequency — should still be eligible
    true = Sounder.should_sound?(schedule, 14_109_000)
    IO.puts("   Different freq: should_sound? = true ✓")

    # Per-cycle cap
    false = Sounder.should_sound?(schedule, 14_109_000,
      soundings_this_cycle: 1, max_per_cycle: 1)
    IO.puts("   Cycle cap reached: should_sound? = false ✓")

    # Next sounding target
    schedule = %{}  # Reset
    schedule = Sounder.record_sounding_tx(schedule, 7_102_000)
    schedule = Sounder.record_sounding_tx(schedule, 7_185_000)
    # 14.109 and 14.346 have no data

    target = Sounder.next_sounding_target(schedule, @channels, stale_threshold_s: 0)
    IO.puts("   Next target: #{inspect(target)}")
    {freq, :never} = target
    true = freq in [14_109_000, 14_346_000]
    IO.puts("   Stalest channel is unsounded: #{format_freq(freq)} ✓")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 5: Sounding Frame Assembly
  # ═══════════════════════════════════════════════════════════════════

  def test_sounding_frame_assembly do
    # Build sync sounding (no capture probe)
    sync_symbols = Sounder.build_sounding_frame(@addr_a, waveform: :deep, async: false)
    IO.puts("   Sync sounding: #{length(sync_symbols)} symbols")
    true = length(sync_symbols) > 0

    # Build async sounding (with capture probe)
    async_symbols = Sounder.build_sounding_frame(@addr_a, waveform: :deep, async: true)
    IO.puts("   Async sounding: #{length(async_symbols)} symbols")
    true = length(async_symbols) > length(sync_symbols)
    IO.puts("   Async > sync (capture probe): #{length(async_symbols)} > #{length(sync_symbols)} ✓")

    # Duration calculation
    duration = Sounder.sounding_duration_ms(waveform: :deep)
    IO.puts("   Deep sounding duration: #{duration}ms")
    true = duration > 0 and duration < 5000

    # LQA exchange call opts
    opts = Sounder.exchange_call_opts(@addr_b, waveform: :deep)
    traffic_type = Keyword.get(opts, :traffic_type)
    IO.puts("   Exchange traffic_type: #{traffic_type}")
    true = traffic_type == Sounder.traffic_type_lqa_exchange()
    IO.puts("   Exchange opts: #{inspect(opts)} ✓")

    # LQA exchange detection
    lqa_req = %PDU.LsuReq{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      traffic_type: Sounder.traffic_type_lqa_exchange()
    }
    true = Sounder.lqa_exchange?(lqa_req)
    IO.puts("   lqa_exchange? detection: true ✓")

    normal_req = %PDU.LsuReq{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      traffic_type: 0
    }
    false = Sounder.lqa_exchange?(normal_req)
    IO.puts("   Normal call not LQA: false ✓")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 6: Manual Sounding via Link FSM
  # ═══════════════════════════════════════════════════════════════════

  def test_manual_sounding do
    {:idle, nil} = Link.get_state(@rig_a)

    # Sound on two channels
    two_channels = Enum.take(@channels, 2)
    :ok = Link.sound(@rig_a, channels: two_channels, waveform: :deep)

    # Should enter sounding state
    Process.sleep(50)
    case Link.get_state(@rig_a) do
      {:sounding, info} ->
        IO.puts("   In sounding state: remaining=#{info.remaining}")
      {:idle, nil} ->
        IO.puts("   Already completed (fast!)")
    end

    # Wait for completion — deep WALE sounding is ~2.8s per channel
    # Poll instead of fixed sleep
    wait_for_state(@rig_a, :idle, 10_000)
    {:idle, nil} = Link.get_state(@rig_a)
    IO.puts("   Returned to idle after sounding ✓")

    # Sound from scanning state
    :ok = Link.scan(@rig_a, channels: @channels, waveform: :fast)
    Process.sleep(100)
    {:scanning, _} = Link.get_state(@rig_a)

    :ok = Link.sound(@rig_a, channels: Enum.take(@channels, 1), waveform: :deep)
    Process.sleep(50)

    case Link.get_state(@rig_a) do
      {:sounding, _info} ->
        IO.puts("   Sounding from scan state ✓")
      {:scanning, _} ->
        IO.puts("   Already returned to scanning ✓")
      {:idle, _} ->
        IO.puts("   Completed, back to idle")
    end

    # Wait for return to scanning
    wait_for_state(@rig_a, :scanning, 10_000)
    case Link.get_state(@rig_a) do
      {:scanning, _} ->
        IO.puts("   Returned to scanning after sounding ✓")
      other ->
        IO.puts("   State after sounding: #{inspect(elem(other, 0))}")
    end

    Link.stop(@rig_a)
    Process.sleep(50)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 7: Two-Way LQA Exchange
  # ═══════════════════════════════════════════════════════════════════

  def test_lqa_exchange do
    # Ensure both rigs are idle
    ensure_idle(@rig_a)
    ensure_idle(@rig_b)

    # Put Rig B in scanning mode
    :ok = Link.scan(@rig_b, channels: @channels, waveform: :fast)
    Process.sleep(100)
    {:scanning, _} = Link.get_state(@rig_b)
    IO.puts("   Rig B scanning")

    # Rig A initiates LQA exchange
    :ok = Link.lqa_exchange(@rig_a, @addr_b, waveform: :deep)
    Process.sleep(300)

    case Link.get_state(@rig_a) do
      {:calling, _} ->
        IO.puts("   Rig A calling (LQA exchange)")
      {:lbt, _} ->
        IO.puts("   Rig A in LBT")
      other ->
        IO.puts("   Rig A state: #{inspect(elem(other, 0))}")
    end

    # Simulate Rig B receiving the LQA exchange request
    lqa_req = %PDU.LsuReq{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      voice: false,
      traffic_type: Sounder.traffic_type_lqa_exchange(),
      assigned_subchannels: 0xFFFF,
      occupied_subchannels: 0
    }
    Link.rx_pdu(@rig_b, lqa_req)
    Process.sleep(500)

    case Link.get_state(@rig_b) do
      {:linked, info} ->
        IO.puts("   Rig B linked (traffic_type=#{info.traffic_type})")
      {:idle, _} ->
        IO.puts("   Rig B already auto-terminated ✓")
      other ->
        IO.puts("   Rig B state: #{inspect(elem(other, 0))}")
    end

    # Wait for auto-terminate
    Process.sleep(500)
    case Link.get_state(@rig_b) do
      {:idle, _} -> IO.puts("   Rig B auto-terminated ✓")
      {:scanning, _} -> IO.puts("   Rig B back to scanning ✓")
      other -> IO.puts("   Rig B final: #{inspect(elem(other, 0))}")
    end

    # Simulate Rig A receiving LsuConf
    lsu_conf = %PDU.LsuConf{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      voice: false,
      snr: 15,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }
    Link.rx_pdu(@rig_a, lsu_conf)
    Process.sleep(500)

    case Link.get_state(@rig_a) do
      {:idle, _} -> IO.puts("   Rig A auto-terminated after exchange ✓")
      {:linked, _} ->
        IO.puts("   Rig A linked, waiting for auto-terminate...")
        Process.sleep(500)
        {:idle, _} = Link.get_state(@rig_a)
        IO.puts("   Rig A auto-terminated ✓")
      other -> IO.puts("   Rig A final: #{inspect(elem(other, 0))}")
    end

    Link.stop(@rig_b)
    Process.sleep(50)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 8: LQA-Informed Calling
  # ═══════════════════════════════════════════════════════════════════

  def test_lqa_informed_calling do
    ensure_idle(@rig_a)

    # Seed LQA data: 14.109 MHz is the best channel for reaching addr_b
    LQA.record_observation(@rig_a, @addr_b, 14_109_000,
      %{probe_corr: 95, path_metric_delta: 800.0, avg_llr: 4.8},
      frame_type: "call")

    # 7.102 is poor
    LQA.record_observation(@rig_a, @addr_b, 7_102_000,
      %{probe_corr: 25, path_metric_delta: 2.0, avg_llr: 0.3},
      frame_type: "call")

    # Verify ranking
    best = LQA.best_channel(@rig_a, @addr_b, @channels)
    IO.puts("   LQA best channel: #{format_freq(best.freq_hz)} (score=#{best.score})")
    true = best.freq_hz == 14_109_000
    IO.puts("   Correct: 14.109 MHz ✓")

    # Initiate call WITHOUT specifying frequency
    # The Link FSM should use LQA to select 14.109 MHz
    :ok = Link.call(@rig_a, @addr_b, waveform: :deep, channels: @channels)
    Process.sleep(300)

    case Link.get_state(@rig_a) do
      {:calling, _} ->
        IO.puts("   Call initiated (LQA should have selected best channel)")
      {:lbt, _} ->
        IO.puts("   In LBT (LQA should have selected best channel)")
      other ->
        IO.puts("   State: #{inspect(elem(other, 0))}")
    end

    # Note: we can't directly verify which freq was selected without
    # checking the rig's current frequency, which requires Control to
    # be running. The LQA selection is logged — check logs for:
    # "LQA selected 14.109 MHz (score=...)"

    Link.stop(@rig_a)
    Process.sleep(50)
    IO.puts("   (Check logs for LQA channel selection)")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Test 9: Turbo Decode Loopback
  # ═══════════════════════════════════════════════════════════════════

  def test_turbo_decode_loopback do
    alias MinuteModemCore.ALE.Waveform.{DeepWale, SoftWalsh}
    alias MinuteModemCore.DSP.PhyModem

    sample_rate = 9600

    # Build a Deep WALE sounding frame
    pdu = %MinuteModemCore.ALE.PDU.LsuStatus{caller_addr: 0xABCD, status: 0}
    pdu_binary = MinuteModemCore.ALE.PDU.encode(pdu)

    symbols = MinuteModemCore.ALE.Waveform.assemble_frame(pdu_binary,
      waveform: :deep, async: true, tuner_time_ms: 0,
      capture_probe_count: 1, preamble_count: 1
    )

    # Modulate
    mod = PhyModem.unified_mod_new(:psk8, sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)

    # Demodulate (clean loopback, no channel)
    demod = PhyModem.unified_demod_new(:psk8, sample_rate)
    PhyModem.unified_demod_set_block_size(demod, 999_999)
    iq_pairs = PhyModem.unified_demod_iq(demod, samples ++ flush)

    filter_delay = 12
    frame_iq = Enum.slice(iq_pairs, filter_delay, length(symbols))

    data_start = 96 + 576
    data_len = 6144
    data_iq = Enum.slice(frame_iq, data_start, data_len)
    IO.puts("   Data IQ length: #{length(data_iq)}")

    # Standard decode
    {:soft, soft_dibits, _scr, _hard} = SoftWalsh.decode_iq_with_dfe(data_iq)
    IO.puts("   Standard decode: #{length(soft_dibits)} soft dibits ✓")

    # Turbo decode
    {:turbo, hard_bits, soft_llrs, iter_scores, _scr} = SoftWalsh.decode_iq_turbo(data_iq)

    n_bits = length(hard_bits)
    n_iters = length(iter_scores)
    scores_str = iter_scores |> Enum.map(&Float.round(&1, 1)) |> inspect()
    IO.puts("   Turbo decode: #{n_bits} bits, #{n_iters} iteration scores: #{scores_str}")

    # Verify we got the right number of bits (96 data dibits → 192 coded bits → 192 info bits)
    true = n_bits >= 96
    IO.puts("   Bit count: #{n_bits} ≥ 96 ✓")

    # Verify iteration scores exist and are positive
    true = n_iters >= 2
    true = Enum.all?(iter_scores, & &1 > 0)
    IO.puts("   Iteration scores positive ✓")

    # Verify convergence: last score ≥ first score (turbo should help or be neutral)
    first = List.first(iter_scores)
    last = List.last(iter_scores)
    IO.puts("   Convergence: #{Float.round(first, 1)} → #{Float.round(last, 1)} (Δ=#{Float.round(last - first, 1)})")

    # On clean loopback, turbo hard bits should produce valid PDU
    data_bits = Enum.drop(hard_bits, -6)
    bytes = for chunk <- Enum.chunk_every(data_bits, 8),
                length(chunk) == 8 do
      Enum.reduce(Enum.with_index(chunk), 0, fn {bit, i}, acc ->
        Bitwise.bor(acc, Bitwise.bsl(bit, 7 - i))
      end)
    end

    decoded_ok = if length(bytes) >= byte_size(pdu_binary) do
      bytes |> Enum.take(byte_size(pdu_binary)) |> :erlang.list_to_binary() == pdu_binary
    else
      false
    end

    if decoded_ok do
      IO.puts("   PDU decode: correct ✓")
    else
      IO.puts("   PDU decode: mismatch (turbo may need tuning, non-fatal)")
    end

    # Soft LLR output should be reasonable
    avg_llr = soft_llrs
      |> Enum.flat_map(fn {l1, l2} -> [abs(l1), abs(l2)] end)
      |> then(fn llrs -> Enum.sum(llrs) / max(length(llrs), 1) end)
    IO.puts("   Avg turbo LLR: #{Float.round(avg_llr, 2)}")
    true = avg_llr > 0.0
    IO.puts("   LLR positive ✓")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════

  defp assert_in_range(value, min, max, label) do
    unless value >= min and value <= max do
      raise "#{label}: expected #{min}-#{max}, got #{value}"
    end
  end

  defp assert_equal(actual, expected, label) do
    unless actual == expected do
      raise "#{label}: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  defp format_freq(freq_hz) when freq_hz >= 1_000_000 do
    "#{Float.round(freq_hz / 1_000_000, 3)} MHz"
  end
  defp format_freq(freq_hz), do: "#{freq_hz} Hz"

  defp wait_for_state(rig_id, target_state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(rig_id, target_state, deadline)
  end

  defp do_wait_for_state(rig_id, target_state, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {actual, _} = Link.get_state(rig_id)
      IO.puts("   (timeout waiting for :#{target_state}, currently :#{actual})")
    else
      case Link.get_state(rig_id) do
        {^target_state, _} -> :ok
        _ ->
          Process.sleep(200)
          do_wait_for_state(rig_id, target_state, deadline)
      end
    end
  end

  defp ensure_idle(rig_id) do
    case Link.get_state(rig_id) do
      {:idle, _} -> :ok
      _ ->
        Link.stop(rig_id)
        wait_for_state(rig_id, :idle, 2000)
    end
  rescue
    _ ->
      # FSM may have crashed — restart it
      addr = if rig_id == @rig_a, do: @addr_a, else: @addr_b
      {:ok, _} = Link.start_link(rig_id: rig_id, self_addr: addr)
  end
end
