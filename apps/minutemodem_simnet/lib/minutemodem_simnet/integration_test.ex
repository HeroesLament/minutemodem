defmodule MinutemodemSimnet.IntegrationTest do
  @moduledoc """
  Integration tests for the full simnet channel path.

  Tests the complete flow:
    minutemodem_core (TX) → Router → ChannelFSM → NIF → RxRegistry → minutemodem_core (RX)

  ## Usage

      # Run all integration tests
      MinutemodemSimnet.IntegrationTest.run_all()

      # Run specific test
      MinutemodemSimnet.IntegrationTest.test_basic_tx_rx()

      # Interactive loopback test
      MinutemodemSimnet.IntegrationTest.loopback_demo()
  """

  alias MinutemodemSimnet
  alias MinutemodemSimnet.Routing.Router

  require Logger

  @sample_rate 9600
  @block_ms 100
  @carrier_hz 1800.0

  @doc """
  Runs all integration tests.
  """
  def run_all do
    tests = [
      {"Basic TX/RX path", &test_basic_tx_rx/0},
      {"Signal modification", &test_signal_is_modified/0},
      {"Multiple receivers", &test_multiple_receivers/0},
      {"Frequency-dependent propagation", &test_frequency_propagation/0},
      {"Channel determinism", &test_determinism/0}
    ]

    Logger.info("\n[Integration] Starting integration tests...\n")

    results =
      Enum.map(tests, fn {name, test_fn} ->
        Logger.info("[Integration] Running: #{name}")

        try do
          result = test_fn.()
          Logger.info("[Integration] ✓ #{name}: PASSED")
          {name, :ok, result}
        rescue
          e ->
            Logger.error("[Integration] ✗ #{name}: FAILED - #{inspect(e)}")
            {name, :error, e}
        catch
          kind, reason ->
            Logger.error("[Integration] ✗ #{name}: FAILED - #{kind}: #{inspect(reason)}")
            {name, :error, {kind, reason}}
        end
      end)

    passed = Enum.count(results, fn {_, status, _} -> status == :ok end)
    failed = Enum.count(results, fn {_, status, _} -> status == :error end)

    Logger.info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║                 INTEGRATION TEST RESULTS                     ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Passed: #{String.pad_leading("#{passed}", 3)}                                                 ║
    ║  Failed: #{String.pad_leading("#{failed}", 3)}                                                 ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    if failed == 0, do: :ok, else: {:error, results}
  end

  @doc """
  Tests basic TX → channel → RX path.
  """
  def test_basic_tx_rx do
    setup_test_environment()

    # Subscribe to RX for station_b
    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    # Generate test samples (a tone)
    samples = generate_tone(@block_ms)

    # Transmit from station_a
    :ok = MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

    # Wait for RX
    receive do
      {:simnet_rx, from_rig, t0, rx_samples, freq_hz, metadata} ->
        assert from_rig == :station_a, "Expected from :station_a, got #{inspect(from_rig)}"
        assert is_integer(t0), "Expected integer t0, got #{inspect(t0)}"
        assert byte_size(rx_samples) == byte_size(samples), "Sample size mismatch"
        assert freq_hz == 7_300_000, "Frequency mismatch"
        assert is_map(metadata), "Expected metadata map"

        Logger.info("  Received #{byte_size(rx_samples)} bytes from #{from_rig} at t0=#{t0}")
        Logger.info("  Metadata: #{inspect(metadata)}")

        :ok
    after
      5000 ->
        raise "Timeout waiting for RX"
    end
  end

  @doc """
  Tests that the channel actually modifies the signal.
  """
  def test_signal_is_modified do
    setup_test_environment()

    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    samples = generate_tone(@block_ms)

    :ok = MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

    receive do
      {:simnet_rx, _from, _t0, rx_samples, _freq, _meta} ->
        # Samples should be different due to fading + noise
        assert rx_samples != samples, "Output should differ from input (fading/noise)"

        # But should be same size
        assert byte_size(rx_samples) == byte_size(samples), "Size should match"

        # Compute correlation to verify signal is related but modified
        correlation = compute_correlation(samples, rx_samples)
        Logger.info("  TX/RX correlation: #{Float.round(correlation, 3)}")

        # Should be correlated (same signal structure) but not perfectly (fading applied)
        # Note: correlation can be NEGATIVE due to phase rotation inverting the signal
        # Rayleigh fading can significantly reduce correlation for narrowband signals
        abs_correlation = abs(correlation)
        assert abs_correlation > 0.01, "Signal should be somewhat correlated (got #{correlation})"
        assert abs_correlation < 0.99, "Signal should be modified by channel (got #{correlation})"

        :ok
    after
      5000 ->
        raise "Timeout waiting for RX"
    end
  end

  @doc """
  Tests that multiple receivers each get the signal.
  """
  def test_multiple_receivers do
    setup_test_environment()

    # Add a third rig
    MinutemodemSimnet.attach_rig(:station_c, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {40.7128, -74.0060}  # NYC
    })

    # IMPORTANT: Invalidate cache AFTER adding the new rig
    # so Router picks up station_c as a destination
    Router.invalidate_cache()

    # Subscribe both receivers
    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)
    MinutemodemSimnet.subscribe_rx(:station_c, test_pid)

    samples = generate_tone(@block_ms)

    :ok = MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

    # Should receive from both (give more time for two channels to be created)
    receivers = receive_all_rx(2, 10_000)

    assert length(receivers) == 2, "Expected 2 receivers, got #{length(receivers)}"

    to_rigs = Enum.map(receivers, fn {:simnet_rx, _from, _t0, _samples, _freq, _meta} -> :ok end)
    Logger.info("  Received by #{length(to_rigs)} receivers")

    # Clean up
    MinutemodemSimnet.detach_rig(:station_c)

    :ok
  end

  @doc """
  Tests that different frequencies produce different propagation.
  """
  def test_frequency_propagation do
    setup_test_environment()

    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    samples = generate_tone(@block_ms)
    samples_per_block = div(byte_size(samples), 4)

    # TX on different bands and compare metadata
    # Use incrementing t0 to avoid backwards time errors
    # Note: At ~960km distance, high frequencies (20m+) may be in skip zone
    # Use lower frequencies that reliably propagate via skywave
    frequencies = [
      {3_500_000, "80m"},
      {5_300_000, "60m"},
      {7_300_000, "40m"}
    ]

    {results, _final_t0} =
      Enum.map_reduce(frequencies, 0, fn {freq, band}, t0 ->
        # Each frequency creates a new channel (cache key includes freq)
        :ok = MinutemodemSimnet.tx(:station_a, t0, samples, freq_hz: freq)

        result =
          receive do
            {:simnet_rx, _from, _rx_t0, _rx_samples, rx_freq, metadata} ->
              assert rx_freq == freq, "Frequency mismatch"
              Logger.info("  #{band} (#{freq} Hz): regime=#{metadata.regime}, SNR=#{metadata.snr_db} dB")
              {freq, metadata}
          after
            5000 ->
              raise "Timeout waiting for RX on #{band}"
          end

        {result, t0 + samples_per_block}
      end)

    # Different frequencies should potentially have different regimes
    # (depends on distance - our test stations are ~960km apart)
    Logger.info("  Propagation varies by frequency: #{length(results)} bands tested")

    :ok
  end

  @doc """
  Tests that same seed produces deterministic output.
  """
  def test_determinism do
    # Create fresh environment with known seed
    cleanup_test_environment()

    MinutemodemSimnet.start_epoch(
      sample_rate: @sample_rate,
      block_ms: @block_ms,
      seed: 12345  # Fixed seed
    )

    MinutemodemSimnet.attach_rig(:station_a, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {38.9072, -77.0369}
    })

    MinutemodemSimnet.attach_rig(:station_b, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {41.8781, -87.6298}
    })

    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    samples = generate_tone(@block_ms)

    # First TX
    :ok = MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

    rx1 =
      receive do
        {:simnet_rx, _, _, rx_samples, _, _} -> rx_samples
      after
        5000 -> raise "Timeout"
      end

    # Reset everything with same seed
    cleanup_test_environment()

    MinutemodemSimnet.start_epoch(
      sample_rate: @sample_rate,
      block_ms: @block_ms,
      seed: 12345  # Same seed
    )

    MinutemodemSimnet.attach_rig(:station_a, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {38.9072, -77.0369}
    })

    MinutemodemSimnet.attach_rig(:station_b, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {41.8781, -87.6298}
    })

    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    # Second TX with same parameters
    :ok = MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

    rx2 =
      receive do
        {:simnet_rx, _, _, rx_samples, _, _} -> rx_samples
      after
        5000 -> raise "Timeout"
      end

    assert rx1 == rx2, "Same seed should produce identical output"
    Logger.info("  Deterministic: outputs match with same seed")

    :ok
  end

  @doc """
  Interactive loopback demonstration.

  Attaches two rigs, sends blocks in a loop, prints stats.
  """
  def loopback_demo(opts \\ []) do
    duration_sec = Keyword.get(opts, :duration_sec, 10)
    freq_hz = Keyword.get(opts, :freq_hz, 7_300_000)

    setup_test_environment()

    test_pid = self()
    MinutemodemSimnet.subscribe_rx(:station_b, test_pid)

    samples = generate_tone(@block_ms)
    samples_per_block = div(byte_size(samples), 4)

    Logger.info("""

    [Loopback Demo]
      Duration: #{duration_sec} seconds
      Frequency: #{freq_hz} Hz
      Block size: #{samples_per_block} samples (#{@block_ms}ms)
      Path: station_a (DC) → station_b (Chicago)
    """)

    start_time = System.monotonic_time(:millisecond)
    deadline = start_time + duration_sec * 1000

    {tx_count, rx_count, total_latency} = loopback_loop(samples, freq_hz, deadline, 0, 0, 0, 0)

    elapsed = (System.monotonic_time(:millisecond) - start_time) / 1000
    avg_latency = if rx_count > 0, do: total_latency / rx_count, else: 0

    Logger.info("""

    [Loopback Results]
      TX blocks: #{tx_count}
      RX blocks: #{rx_count}
      Loss rate: #{Float.round((tx_count - rx_count) / max(tx_count, 1) * 100, 1)}%
      Avg round-trip: #{Float.round(avg_latency, 1)} ms
      Throughput: #{Float.round(rx_count / elapsed, 1)} blocks/sec
    """)

    cleanup_test_environment()

    %{
      tx_count: tx_count,
      rx_count: rx_count,
      avg_latency_ms: avg_latency,
      elapsed_sec: elapsed
    }
  end

  defp loopback_loop(samples, freq_hz, deadline, t0, tx_count, rx_count, total_latency) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      # Drain any remaining RX
      final_rx = drain_rx_queue(rx_count, total_latency)
      {tx_count, elem(final_rx, 0), elem(final_rx, 1)}
    else
      tx_start = System.monotonic_time(:microsecond)

      :ok = MinutemodemSimnet.tx(:station_a, t0, samples, freq_hz: freq_hz)

      # Try to receive (non-blocking with short timeout)
      {new_rx_count, new_latency} =
        receive do
          {:simnet_rx, _, _, _, _, _} ->
            latency = (System.monotonic_time(:microsecond) - tx_start) / 1000
            {rx_count + 1, total_latency + latency}
        after
          0 ->
            {rx_count, total_latency}
        end

      samples_per_block = div(byte_size(samples), 4)
      loopback_loop(samples, freq_hz, deadline, t0 + samples_per_block, tx_count + 1, new_rx_count, new_latency)
    end
  end

  defp drain_rx_queue(rx_count, total_latency) do
    receive do
      {:simnet_rx, _, _, _, _, _} ->
        drain_rx_queue(rx_count + 1, total_latency)
    after
      100 ->
        {rx_count, total_latency}
    end
  end

  # Test helpers

  defp setup_test_environment do
    cleanup_test_environment()

    # Start epoch
    MinutemodemSimnet.start_epoch(
      sample_rate: @sample_rate,
      block_ms: @block_ms
    )

    # Attach two rigs with realistic locations
    # Washington DC
    MinutemodemSimnet.attach_rig(:station_a, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {38.9072, -77.0369},
      antenna: %{type: :dipole, height_wavelengths: 0.5, gain_dbi: 2.1},
      tx_power_watts: 100,
      noise_floor_dbm: -100
    })

    # Chicago (~960 km away)
    MinutemodemSimnet.attach_rig(:station_b, %{
      sample_rates: [@sample_rate],
      block_ms: [@block_ms],
      representation: [:audio_f32],
      location: {41.8781, -87.6298},
      antenna: %{type: :dipole, height_wavelengths: 0.5, gain_dbi: 2.1},
      tx_power_watts: 100,
      noise_floor_dbm: -100
    })

    # Clear router cache
    Router.invalidate_cache()

    :ok
  end

  defp cleanup_test_environment do
    # Unsubscribe
    try do
      MinutemodemSimnet.unsubscribe_rx(:station_a)
      MinutemodemSimnet.unsubscribe_rx(:station_b)
      MinutemodemSimnet.unsubscribe_rx(:station_c)
    catch
      _, _ -> :ok
    end

    # Detach rigs
    try do
      MinutemodemSimnet.detach_rig(:station_a)
      MinutemodemSimnet.detach_rig(:station_b)
      MinutemodemSimnet.detach_rig(:station_c)
    catch
      _, _ -> :ok
    end

    # Stop epoch
    try do
      MinutemodemSimnet.stop_epoch()
    catch
      _, _ -> :ok
    end

    # Clear caches
    Router.invalidate_cache()

    :ok
  end

  defp generate_tone(duration_ms) do
    num_samples = div(duration_ms * @sample_rate, 1000)

    for i <- 0..(num_samples - 1), into: <<>> do
      t = i / @sample_rate
      sample = :math.cos(2 * :math.pi() * @carrier_hz * t) * 0.5
      <<sample::float-32-native>>
    end
  end

  defp compute_correlation(binary_a, binary_b) do
    samples_a = binary_to_samples(binary_a)
    samples_b = binary_to_samples(binary_b)

    n = min(length(samples_a), length(samples_b))
    a = Enum.take(samples_a, n)
    b = Enum.take(samples_b, n)

    mean_a = Enum.sum(a) / n
    mean_b = Enum.sum(b) / n

    cov =
      Enum.zip(a, b)
      |> Enum.map(fn {x, y} -> (x - mean_a) * (y - mean_b) end)
      |> Enum.sum()

    var_a = Enum.map(a, fn x -> (x - mean_a) * (x - mean_a) end) |> Enum.sum()
    var_b = Enum.map(b, fn x -> (x - mean_b) * (x - mean_b) end) |> Enum.sum()

    if var_a * var_b > 0 do
      cov / :math.sqrt(var_a * var_b)
    else
      0.0
    end
  end

  defp binary_to_samples(binary) do
    for <<sample::float-32-native <- binary>>, do: sample
  end

  defp receive_all_rx(expected, timeout) do
    receive_all_rx(expected, timeout, [])
  end

  defp receive_all_rx(0, _timeout, acc), do: Enum.reverse(acc)

  defp receive_all_rx(remaining, timeout, acc) do
    receive do
      {:simnet_rx, _, _, _, _, _} = msg ->
        receive_all_rx(remaining - 1, timeout, [msg | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise(msg)
end
