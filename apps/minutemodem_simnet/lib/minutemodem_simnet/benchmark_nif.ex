defmodule MinutemodemSimnet.BenchmarkNif do
  @moduledoc """
  Benchmark for isolating NIF/Rust physics performance from Elixir overhead.

  Tests raw throughput of the Watterson channel physics without:
  - Router/caching
  - GenStateMachine calls
  - Horde/distributed coordination
  - Binary copying between processes

  ## Usage

      # Quick validation that NIF works
      MinutemodemSimnet.BenchmarkNif.validate()

      # Single-threaded benchmark
      MinutemodemSimnet.BenchmarkNif.run(10, 5)  # 10 channels, 5 seconds

      # Parallel benchmark
      MinutemodemSimnet.BenchmarkNif.run_parallel(10, 4, 5)  # 10 ch/worker, 4 workers, 5 sec
  """

  alias MinutemodemSimnet.Physics.Channel
  require Logger

  @doc """
  Validate that the NIF is working correctly.

  Runs basic sanity checks:
  1. Channel creation/destruction
  2. Process block returns correct size
  3. Output is different from input (channel is doing something)
  4. Deterministic with same seed
  5. Different seeds produce different output
  """
  def validate do
    Logger.info("[NIF Validate] Starting validation...")

    results = [
      {"Channel lifecycle", validate_lifecycle()},
      {"Process block size", validate_block_size()},
      {"Channel modifies signal", validate_signal_modification()},
      {"Deterministic output", validate_determinism()},
      {"Seed independence", validate_seed_independence()},
      {"State retrieval", validate_get_state()},
      {"Channel count", validate_channel_count()}
    ]

    failures = Enum.filter(results, fn {_name, result} -> result != :ok end)

    if failures == [] do
      Logger.info("""

      ╔══════════════════════════════════════════════════════════════╗
      ║                    NIF VALIDATION PASSED                     ║
      ╠══════════════════════════════════════════════════════════════╣
      #{Enum.map(results, fn {name, _} -> "║  ✓ #{String.pad_trailing(name, 54)}║\n" end)}╚══════════════════════════════════════════════════════════════╝
      """)
      :ok
    else
      Logger.error("""

      ╔══════════════════════════════════════════════════════════════╗
      ║                    NIF VALIDATION FAILED                     ║
      ╠══════════════════════════════════════════════════════════════╣
      #{Enum.map(results, fn {name, result} ->
        status = if result == :ok, do: "✓", else: "✗"
        "║  #{status} #{String.pad_trailing(name, 54)}║\n"
      end)}╠══════════════════════════════════════════════════════════════╣
      ║  Failures:                                                   ║
      #{Enum.map(failures, fn {name, {:error, reason}} ->
        "║    #{String.pad_trailing("#{name}: #{inspect(reason)}", 52)}║\n"
      end)}╚══════════════════════════════════════════════════════════════╝
      """)
      {:error, failures}
    end
  end

  defp validate_lifecycle do
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}

    with {:ok, id} <- Channel.create(params, 12345),
         :ok <- Channel.destroy(id) do
      :ok
    else
      error -> {:error, error}
    end
  end

  defp validate_block_size do
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}
    {:ok, id} = Channel.create(params, 12345)

    # 100 samples * 4 bytes = 400 bytes
    input = for _ <- 1..100, do: <<0.5::float-32-native>>
    input_binary = IO.iodata_to_binary(input)

    result = case Channel.process_block(id, input_binary) do
      {:ok, output} when byte_size(output) == byte_size(input_binary) -> :ok
      {:ok, output} -> {:error, {:size_mismatch, byte_size(input_binary), byte_size(output)}}
      error -> {:error, error}
    end

    Channel.destroy(id)
    result
  end

  defp validate_signal_modification do
    # Use fading channel so output differs from input
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}
    {:ok, id} = Channel.create(params, 12345)

    # Generate a tone
    input = for i <- 0..99 do
      sample = :math.cos(2 * :math.pi() * 1800 * i / 9600) * 0.5
      <<sample::float-32-native>>
    end
    input_binary = IO.iodata_to_binary(input)

    result = case Channel.process_block(id, input_binary) do
      {:ok, output} ->
        # Check that output differs from input
        if output != input_binary do
          :ok
        else
          {:error, :output_equals_input}
        end
      error ->
        {:error, error}
    end

    Channel.destroy(id)
    result
  end

  defp validate_determinism do
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}

    input = <<0.5::float-32-native>> |> :binary.copy(100)

    # Create two channels with same seed
    {:ok, id1} = Channel.create(params, 42)
    {:ok, id2} = Channel.create(params, 42)

    {:ok, out1} = Channel.process_block(id1, input)
    {:ok, out2} = Channel.process_block(id2, input)

    Channel.destroy(id1)
    Channel.destroy(id2)

    if out1 == out2 do
      :ok
    else
      {:error, :outputs_differ_with_same_seed}
    end
  end

  defp validate_seed_independence do
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}

    input = <<0.5::float-32-native>> |> :binary.copy(100)

    # Create two channels with different seeds
    {:ok, id1} = Channel.create(params, 42)
    {:ok, id2} = Channel.create(params, 9999)

    {:ok, out1} = Channel.process_block(id1, input)
    {:ok, out2} = Channel.process_block(id2, input)

    Channel.destroy(id1)
    Channel.destroy(id2)

    if out1 != out2 do
      :ok
    else
      {:error, :outputs_same_with_different_seeds}
    end
  end

  defp validate_get_state do
    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}
    {:ok, id} = Channel.create(params, 12345)

    # Process some samples to advance state
    input = <<0.5::float-32-native>> |> :binary.copy(100)
    {:ok, _} = Channel.process_block(id, input)

    result = case Channel.get_state(id) do
      {:ok, state} when is_map(state) ->
        # Check expected fields exist
        if Map.has_key?(state, :sample_index) do
          :ok
        else
          {:error, {:missing_field, :sample_index, state}}
        end
      error ->
        {:error, error}
    end

    Channel.destroy(id)
    result
  end

  defp validate_channel_count do
    initial_count = Channel.count()

    params = %{sample_rate: 9600, delay_spread_samples: 0, doppler_bandwidth_hz: 1.0, snr_db: 20.0}
    {:ok, id1} = Channel.create(params, 1)
    {:ok, id2} = Channel.create(params, 2)

    count_after_create = Channel.count()

    Channel.destroy(id1)
    Channel.destroy(id2)

    count_after_destroy = Channel.count()

    cond do
      count_after_create != initial_count + 2 ->
        {:error, {:create_count_wrong, initial_count, count_after_create}}
      count_after_destroy != initial_count ->
        {:error, {:destroy_count_wrong, initial_count, count_after_destroy}}
      true ->
        :ok
    end
  end

  @doc """
  Benchmark raw NIF performance.

  ## Options

  - `num_channels`: Number of simultaneous channels to process
  - `duration_sec`: How long to run
  - `samples_per_block`: Samples per process_block call (default 960 for 100ms @ 9600)
  - `sample_rate`: Sample rate in Hz (default 9600)
  - `doppler_hz`: Doppler bandwidth (default 1.0)
  - `snr_db`: SNR in dB (default 20.0)
  """
  def run(num_channels, duration_sec, opts \\ []) do
    samples_per_block = Keyword.get(opts, :samples_per_block, 960)
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    doppler_hz = Keyword.get(opts, :doppler_hz, 1.0)
    snr_db = Keyword.get(opts, :snr_db, 20.0)

    block_duration_ms = samples_per_block / sample_rate * 1000

    Logger.info("[NIF Bench] Creating #{num_channels} channels...")

    params = %{
      sample_rate: sample_rate,
      delay_spread_samples: 0,
      doppler_bandwidth_hz: doppler_hz,
      snr_db: snr_db
    }

    channel_ids = for i <- 1..num_channels do
      {:ok, id} = Channel.create(params, 1000 + i)
      id
    end

    # Pre-generate test samples (a tone at carrier frequency)
    samples = generate_tone_block(samples_per_block, 1800.0, sample_rate)

    Logger.info("[NIF Bench] Running for #{duration_sec} seconds (#{samples_per_block} samples/block = #{Float.round(block_duration_ms, 1)}ms)...")

    start_time = System.monotonic_time(:microsecond)
    deadline = start_time + (duration_sec * 1_000_000)

    # Run tight loop calling process_block on each channel
    {total_blocks, total_latency_us, min_latency, max_latency} =
      nif_loop(channel_ids, samples, deadline, 0, 0, :infinity, 0)

    end_time = System.monotonic_time(:microsecond)
    actual_duration = (end_time - start_time) / 1_000_000

    # Cleanup
    for id <- channel_ids do
      Channel.destroy(id)
    end

    # Calculate results
    blocks_per_sec = total_blocks / actual_duration
    samples_per_sec = blocks_per_sec * samples_per_block
    avg_latency_us = if total_blocks > 0, do: total_latency_us / total_blocks, else: 0

    # Per-channel throughput
    blocks_per_channel_per_sec = blocks_per_sec / num_channels

    # Real-time ratio (how much faster than real-time)
    audio_seconds_per_sec = samples_per_sec / sample_rate
    realtime_ratio = audio_seconds_per_sec

    Logger.info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║                  NIF-ONLY BENCHMARK RESULTS                  ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Configuration                                               ║
    ║    Channels:         #{String.pad_leading("#{num_channels}", 8)}                              ║
    ║    Samples/block:    #{String.pad_leading("#{samples_per_block}", 8)}  (#{String.pad_leading("#{Float.round(block_duration_ms, 1)}ms", 6)})                 ║
    ║    Sample rate:      #{String.pad_leading("#{sample_rate}", 8)} Hz                           ║
    ║    Duration:         #{String.pad_leading("#{Float.round(actual_duration, 2)}s", 8)}                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Aggregate Throughput                                        ║
    ║    Blocks/sec:       #{String.pad_leading("#{trunc(blocks_per_sec)}", 8)}                              ║
    ║    Samples/sec:      #{String.pad_leading(format_number(samples_per_sec), 8)}                              ║
    ║    Real-time ratio:  #{String.pad_leading("#{Float.round(realtime_ratio, 1)}x", 8)}                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Per-Channel Performance                                     ║
    ║    Blocks/ch/sec:    #{String.pad_leading("#{trunc(blocks_per_channel_per_sec)}", 8)}                              ║
    ║    Latency (avg):    #{String.pad_leading("#{Float.round(avg_latency_us, 1)} µs", 8)}                              ║
    ║    Latency (min):    #{String.pad_leading("#{min_latency} µs", 8)}                              ║
    ║    Latency (max):    #{String.pad_leading("#{max_latency} µs", 8)}                              ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    %{
      num_channels: num_channels,
      duration_sec: actual_duration,
      samples_per_block: samples_per_block,
      total_blocks: total_blocks,
      blocks_per_sec: blocks_per_sec,
      samples_per_sec: samples_per_sec,
      blocks_per_channel_per_sec: blocks_per_channel_per_sec,
      realtime_ratio: realtime_ratio,
      avg_latency_us: avg_latency_us,
      min_latency_us: min_latency,
      max_latency_us: max_latency
    }
  end

  defp nif_loop(channel_ids, samples, deadline, total_blocks, total_latency, min_lat, max_lat) do
    now = System.monotonic_time(:microsecond)

    if now >= deadline do
      {total_blocks, total_latency, min_lat, max_lat}
    else
      # Process one block on each channel
      {blocks, latency, new_min, new_max} =
        process_all_channels(channel_ids, samples, 0, 0, min_lat, max_lat)

      nif_loop(channel_ids, samples, deadline,
               total_blocks + blocks, total_latency + latency, new_min, new_max)
    end
  end

  defp process_all_channels([], _samples, blocks, latency, min_lat, max_lat) do
    {blocks, latency, min_lat, max_lat}
  end

  defp process_all_channels([id | rest], samples, blocks, latency, min_lat, max_lat) do
    t0 = System.monotonic_time(:microsecond)
    {:ok, _output} = Channel.process_block(id, samples)
    t1 = System.monotonic_time(:microsecond)

    lat = t1 - t0
    new_min = min(min_lat, lat)
    new_max = max(max_lat, lat)

    process_all_channels(rest, samples, blocks + 1, latency + lat, new_min, new_max)
  end

  @doc """
  Benchmark with parallel workers to test NIF thread safety and scaling.

  ## Options

  Same as `run/3` plus:
  - `num_workers`: Number of parallel Elixir processes
  """
  def run_parallel(num_channels_per_worker, num_workers, duration_sec, opts \\ []) do
    samples_per_block = Keyword.get(opts, :samples_per_block, 960)
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    doppler_hz = Keyword.get(opts, :doppler_hz, 1.0)
    snr_db = Keyword.get(opts, :snr_db, 20.0)

    block_duration_ms = samples_per_block / sample_rate * 1000
    total_channels = num_channels_per_worker * num_workers

    Logger.info("[NIF Bench] Creating #{total_channels} channels across #{num_workers} workers...")

    params = %{
      sample_rate: sample_rate,
      delay_spread_samples: 0,
      doppler_bandwidth_hz: doppler_hz,
      snr_db: snr_db
    }

    # Create all channels upfront
    all_channel_ids = for i <- 1..total_channels do
      {:ok, id} = Channel.create(params, 1000 + i)
      id
    end

    # Split channels among workers
    channel_groups = Enum.chunk_every(all_channel_ids, num_channels_per_worker)

    samples = generate_tone_block(samples_per_block, 1800.0, sample_rate)

    Logger.info("[NIF Bench] Running #{num_workers} workers for #{duration_sec} seconds...")

    # Counters: 1=blocks, 2=latency_us, 3=min_latency, 4=max_latency
    results = :counters.new(4, [:atomics])
    # Initialize min to large value
    :counters.put(results, 3, 999_999_999)

    start_time = System.monotonic_time(:microsecond)
    deadline = start_time + (duration_sec * 1_000_000)

    # Spawn workers
    parent = self()
    workers = for {channel_ids, _idx} <- Enum.with_index(channel_groups) do
      spawn_link(fn ->
        worker_loop(channel_ids, samples, deadline, results)
        send(parent, {:done, self()})
      end)
    end

    # Wait for all workers
    for pid <- workers do
      receive do
        {:done, ^pid} -> :ok
      end
    end

    end_time = System.monotonic_time(:microsecond)
    actual_duration = (end_time - start_time) / 1_000_000

    total_blocks = :counters.get(results, 1)
    total_latency = :counters.get(results, 2)
    min_latency = :counters.get(results, 3)
    max_latency = :counters.get(results, 4)

    # Cleanup
    for id <- all_channel_ids do
      Channel.destroy(id)
    end

    blocks_per_sec = total_blocks / actual_duration
    samples_per_sec = blocks_per_sec * samples_per_block
    avg_latency_us = if total_blocks > 0, do: total_latency / total_blocks, else: 0
    blocks_per_channel_per_sec = blocks_per_sec / total_channels

    audio_seconds_per_sec = samples_per_sec / sample_rate
    realtime_ratio = audio_seconds_per_sec

    Logger.info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║              PARALLEL NIF BENCHMARK RESULTS                  ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Configuration                                               ║
    ║    Workers:          #{String.pad_leading("#{num_workers}", 8)}                              ║
    ║    Channels/worker:  #{String.pad_leading("#{num_channels_per_worker}", 8)}                              ║
    ║    Total channels:   #{String.pad_leading("#{total_channels}", 8)}                              ║
    ║    Samples/block:    #{String.pad_leading("#{samples_per_block}", 8)}  (#{String.pad_leading("#{Float.round(block_duration_ms, 1)}ms", 6)})                 ║
    ║    Duration:         #{String.pad_leading("#{Float.round(actual_duration, 2)}s", 8)}                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Aggregate Throughput                                        ║
    ║    Blocks/sec:       #{String.pad_leading("#{trunc(blocks_per_sec)}", 8)}                              ║
    ║    Samples/sec:      #{String.pad_leading(format_number(samples_per_sec), 8)}                              ║
    ║    Real-time ratio:  #{String.pad_leading("#{Float.round(realtime_ratio, 1)}x", 8)}                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Per-Channel Performance                                     ║
    ║    Blocks/ch/sec:    #{String.pad_leading("#{trunc(blocks_per_channel_per_sec)}", 8)}                              ║
    ║    Latency (avg):    #{String.pad_leading("#{Float.round(avg_latency_us, 1)} µs", 8)}                              ║
    ║    Latency (min):    #{String.pad_leading("#{min_latency} µs", 8)}                              ║
    ║    Latency (max):    #{String.pad_leading("#{max_latency} µs", 8)}                              ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    %{
      num_workers: num_workers,
      num_channels_per_worker: num_channels_per_worker,
      total_channels: total_channels,
      duration_sec: actual_duration,
      samples_per_block: samples_per_block,
      total_blocks: total_blocks,
      blocks_per_sec: blocks_per_sec,
      samples_per_sec: samples_per_sec,
      blocks_per_channel_per_sec: blocks_per_channel_per_sec,
      realtime_ratio: realtime_ratio,
      avg_latency_us: avg_latency_us,
      min_latency_us: min_latency,
      max_latency_us: max_latency
    }
  end

  defp worker_loop(channel_ids, samples, deadline, results) do
    now = System.monotonic_time(:microsecond)

    if now >= deadline do
      :ok
    else
      for id <- channel_ids do
        t0 = System.monotonic_time(:microsecond)
        {:ok, _output} = Channel.process_block(id, samples)
        t1 = System.monotonic_time(:microsecond)

        lat = t1 - t0
        :counters.add(results, 1, 1)
        :counters.add(results, 2, lat)

        # Update min (compare-and-swap loop)
        update_min(results, 3, lat)
        update_max(results, 4, lat)
      end

      worker_loop(channel_ids, samples, deadline, results)
    end
  end

  defp update_min(counter, idx, value) do
    current = :counters.get(counter, idx)
    if value < current do
      :counters.put(counter, idx, value)
      # Re-check in case of race
      new_current = :counters.get(counter, idx)
      if value < new_current, do: update_min(counter, idx, value)
    end
  end

  defp update_max(counter, idx, value) do
    current = :counters.get(counter, idx)
    if value > current do
      :counters.put(counter, idx, value)
    end
  end

  defp generate_tone_block(num_samples, freq_hz, sample_rate) do
    for i <- 0..(num_samples - 1), into: <<>> do
      sample = :math.cos(2 * :math.pi() * freq_hz * i / sample_rate) * 0.5
      <<sample::float-32-native>>
    end
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{trunc(n)}"
end
