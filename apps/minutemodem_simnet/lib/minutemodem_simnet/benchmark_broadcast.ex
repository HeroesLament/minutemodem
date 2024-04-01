defmodule MinutemodemSimnet.BenchmarkBroadcast do
  @moduledoc """
  Benchmark simulating NVIS broadcast: one station TX to N-1 receivers.

  Models the realistic ALE scenario where:
  - One station transmits
  - All other stations in the NVIS coverage area receive
  - Each RX path has its own Watterson channel impairments
  """

  alias MinutemodemSimnet.Physics.Channel
  require Logger

  @doc """
  Simulate one TX to N-1 receivers.

  - `num_receivers`: Number of receiving stations (N-1)
  - `duration_sec`: How long to run
  - `sample_rate`: Audio sample rate (e.g., 48000 for wideband)
  - `block_ms`: Block duration in milliseconds
  """
  def run(num_receivers, duration_sec, opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 48000)
    block_ms = Keyword.get(opts, :block_ms, 2)
    samples_per_block = div(sample_rate * block_ms, 1000)

    total_stations = num_receivers + 1

    Logger.info("[Broadcast] Simulating #{total_stations} station NVIS network")
    Logger.info("[Broadcast] 1 TX → #{num_receivers} RX, #{sample_rate}Hz, #{block_ms}ms blocks (#{samples_per_block} samples)")

    # Create channels for TX → each RX
    params = %{
      delay_spread_samples: div(sample_rate * 2, 1000),  # 2ms delay spread
      doppler_bandwidth_hz: 1.0,  # Moderate fading
      snr_db: 15.0,
      sample_rate: sample_rate
    }

    Logger.info("[Broadcast] Creating #{num_receivers} channels...")

    channel_ids = for i <- 1..num_receivers do
      {:ok, id} = Channel.create(params, 1000 + i)
      id
    end

    # Pre-generate TX samples (same for all channels - it's a broadcast)
    tx_samples = generate_samples(samples_per_block)

    Logger.info("[Broadcast] Running for #{duration_sec} seconds...")

    start_time = System.monotonic_time(:microsecond)
    deadline = start_time + (duration_sec * 1_000_000)

    # Run broadcast loop
    {total_blocks, latencies} = broadcast_loop(channel_ids, tx_samples, deadline, 0, [])

    end_time = System.monotonic_time(:microsecond)
    actual_duration = (end_time - start_time) / 1_000_000

    # Cleanup
    for id <- channel_ids do
      Channel.destroy(id)
    end

    # Calculate results
    blocks_per_sec = total_blocks / actual_duration
    target_blocks_per_sec = 1000 / block_ms

    sorted_latencies = Enum.sort(latencies)
    avg_latency = if length(sorted_latencies) > 0, do: Enum.sum(sorted_latencies) / length(sorted_latencies), else: 0
    p99_latency = if length(sorted_latencies) > 0, do: Enum.at(sorted_latencies, trunc(length(sorted_latencies) * 0.99)), else: 0
    max_latency = if length(sorted_latencies) > 0, do: List.last(sorted_latencies), else: 0

    realtime_ratio = blocks_per_sec / target_blocks_per_sec

    Logger.info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║              NVIS BROADCAST BENCHMARK RESULTS                ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Configuration                                               ║
    ║    Stations:       #{String.pad_leading("#{total_stations}", 10)}                            ║
    ║    Receivers:      #{String.pad_leading("#{num_receivers}", 10)}                            ║
    ║    Sample rate:    #{String.pad_leading("#{sample_rate} Hz", 10)}                            ║
    ║    Block size:     #{String.pad_leading("#{block_ms}ms (#{samples_per_block})", 10)}                            ║
    ║    Duration:       #{String.pad_leading("#{Float.round(actual_duration, 2)}s", 10)}                            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Throughput                                                  ║
    ║    Blocks/sec:     #{String.pad_leading("#{trunc(blocks_per_sec)}", 10)}                            ║
    ║    Target:         #{String.pad_leading("#{trunc(target_blocks_per_sec)}", 10)}  (realtime)                  ║
    ║    Realtime ratio: #{String.pad_leading("#{Float.round(realtime_ratio, 1)}x", 10)}                            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Latency (per broadcast, all #{num_receivers} channels)                    ║
    ║    Average:        #{String.pad_leading("#{trunc(avg_latency)} µs", 10)}                            ║
    ║    P99:            #{String.pad_leading("#{trunc(p99_latency)} µs", 10)}                            ║
    ║    Max:            #{String.pad_leading("#{trunc(max_latency)} µs", 10)}                            ║
    ║    Budget:         #{String.pad_leading("#{block_ms * 1000} µs", 10)}  (#{block_ms}ms block)               ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Verdict: #{String.pad_trailing(verdict(realtime_ratio, avg_latency, block_ms * 1000), 51)}║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    %{
      total_stations: total_stations,
      num_receivers: num_receivers,
      sample_rate: sample_rate,
      block_ms: block_ms,
      samples_per_block: samples_per_block,
      duration_sec: actual_duration,
      total_blocks: total_blocks,
      blocks_per_sec: blocks_per_sec,
      target_blocks_per_sec: target_blocks_per_sec,
      realtime_ratio: realtime_ratio,
      avg_latency_us: avg_latency,
      p99_latency_us: p99_latency,
      max_latency_us: max_latency
    }
  end

  defp broadcast_loop(channel_ids, tx_samples, deadline, total_blocks, latencies) do
    now = System.monotonic_time(:microsecond)

    if now >= deadline do
      {total_blocks, latencies}
    else
      # Time the entire broadcast (same TX to all channels)
      t0 = System.monotonic_time(:microsecond)

      # Process through ALL channels (this is one "broadcast")
      for id <- channel_ids do
        {:ok, _rx_samples} = Channel.process_block(id, tx_samples)
      end

      t1 = System.monotonic_time(:microsecond)
      latency = t1 - t0

      broadcast_loop(channel_ids, tx_samples, deadline, total_blocks + 1, [latency | latencies])
    end
  end

  defp generate_samples(num_samples) do
    # Generate realistic-ish audio (sine wave at 1kHz)
    for i <- 0..(num_samples - 1), into: <<>> do
      sample = :math.sin(2 * :math.pi * 1000 * i / 48000)
      <<sample::float-32-native>>
    end
  end

  defp verdict(realtime_ratio, avg_latency, budget_us) do
    cond do
      realtime_ratio >= 1.0 and avg_latency < budget_us * 0.5 ->
        "✅ EXCELLENT - plenty of headroom"
      realtime_ratio >= 1.0 and avg_latency < budget_us ->
        "✅ GOOD - meets realtime"
      realtime_ratio >= 0.9 ->
        "⚠️  MARGINAL - close to realtime limit"
      true ->
        "❌ INSUFFICIENT - cannot meet realtime"
    end
  end

  @doc """
  Test scaling: how many receivers can we handle at realtime?
  """
  def find_limit(opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 48000)
    block_ms = Keyword.get(opts, :block_ms, 2)

    Logger.info("[Broadcast] Finding receiver limit for #{sample_rate}Hz, #{block_ms}ms blocks...")

    find_limit_loop(10, sample_rate, block_ms)
  end

  defp find_limit_loop(num_receivers, sample_rate, block_ms) do
    result = run(num_receivers, 2, sample_rate: sample_rate, block_ms: block_ms)

    cond do
      result.realtime_ratio < 1.0 ->
        Logger.info("[Broadcast] Limit found: #{num_receivers - 10} receivers at realtime")
        num_receivers - 10

      num_receivers >= 500 ->
        Logger.info("[Broadcast] Tested up to 500 receivers, all OK!")
        500

      true ->
        find_limit_loop(num_receivers + 10, sample_rate, block_ms)
    end
  end
end
