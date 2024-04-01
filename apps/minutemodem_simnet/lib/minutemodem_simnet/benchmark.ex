defmodule MinutemodemSimnet.Benchmark do
  @moduledoc """
  Bandwidth and latency benchmarks for the simnet.

  Measures:
  - TX throughput (blocks/sec, samples/sec)
  - End-to-end latency (TX call to FSM processing complete)
  - Channel creation rate
  - Memory usage (NIF slab, BEAM processes)

  ## Usage

      # Quick 10-second test with 3 rigs
      MinutemodemSimnet.Benchmark.run(3, 10)

      # Stress test with 10 rigs for 60 seconds
      MinutemodemSimnet.Benchmark.run(10, 60)
  """

  require Logger

  defmodule Stats do
    @moduledoc false
    defstruct [
      :num_rigs,
      :num_channels,
      :duration_sec,
      :total_blocks,
      :total_samples,
      :blocks_per_sec,
      :samples_per_sec,
      :bytes_per_sec,
      :avg_latency_us,
      :p99_latency_us,
      :max_latency_us,
      :channel_count,
      :dropped_blocks,
      :errors
    ]
  end

  @doc """
  Run a bandwidth test with `num_rigs` rigs for `duration_sec` seconds.

  Returns a Stats struct with results.
  """
  def run(num_rigs, duration_sec, opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    block_ms = Keyword.get(opts, :block_ms, 2)
    samples_per_block = div(sample_rate * block_ms, 1000)

    Logger.info("[Benchmark] Starting: #{num_rigs} rigs, #{duration_sec}s, #{sample_rate} sps, #{block_ms}ms blocks")

    # Stop any existing epoch
    MinutemodemSimnet.stop_epoch()

    # Wait for epoch to actually stop
    wait_for_no_epoch()

    # Setup
    {:ok, rigs} = setup_rigs(num_rigs)
    {:ok, _epoch_id} = MinutemodemSimnet.start_epoch(sample_rate: sample_rate, block_ms: block_ms)

    # Pre-generate test samples (slight variation per rig for realism)
    samples_map = for {rig, i} <- Enum.with_index(rigs), into: %{} do
      amplitude = 0.5 + (i * 0.01)
      samples = <<amplitude::float-32-native>> |> :binary.copy(samples_per_block)
      {rig, samples}
    end

    # Warm up - prime the channels by doing one TX from each rig
    # First invalidate any stale cache from previous runs
    Logger.info("[Benchmark] Warming up channels...")
    MinutemodemSimnet.Routing.Router.invalidate_cache()
    for rig <- rigs do
      MinutemodemSimnet.tx(rig, 0, samples_map[rig])
    end

    # Reset for actual test
    latencies = :ets.new(:benchmark_latencies, [:duplicate_bag, :public])
    errors = :counters.new(1, [:atomics])
    successes = :counters.new(1, [:atomics])

    # Spawn workers and let them warm up before we start timing
    parent = self()
    worker_pids = for rig <- rigs do
      spawn_link(fn ->
        # Worker warmup: create all channels for this rig
        warmup_result = MinutemodemSimnet.tx(rig, 0, samples_map[rig])

        # Log destinations for debugging
        dest_cache = Process.get(:router_cached_destinations) || %{}
        destinations = Map.get(dest_cache, rig, [])
        Logger.info("[Benchmark] #{inspect(rig)} warmup: #{inspect(warmup_result)}, destinations: #{length(destinations)}")

        # Signal ready and wait for start
        send(parent, {:ready, self()})
        receive do
          :start -> :ok
        end

        # Now run the timed portion
        deadline = receive do
          {:deadline, d} -> d
        end

        tx_loop_timed(rig, samples_map[rig], samples_per_block, 1, block_ms * 1000, deadline, latencies, errors, successes)
        send(parent, {:worker_done, self()})
      end)
    end

    # Wait for all workers to be ready (warmup complete)
    for pid <- worker_pids do
      receive do
        {:ready, ^pid} -> :ok
      end
    end

    Logger.info("[Benchmark] Running for #{duration_sec} seconds...")

    # Now start timing
    start_time = System.monotonic_time(:microsecond)
    deadline = start_time + (duration_sec * 1_000_000)

    # Signal workers to start with the deadline
    for pid <- worker_pids do
      send(pid, :start)
      send(pid, {:deadline, deadline})
    end

    # Collect refs for monitoring
    workers = for pid <- worker_pids do
      {pid, Process.monitor(pid)}
    end

    # Wait for all workers to complete
    wait_for_workers(workers)

    end_time = System.monotonic_time(:microsecond)
    actual_duration_us = end_time - start_time

    # Log success count for debugging
    success_count = :counters.get(successes, 1)
    error_count = :counters.get(errors, 1)
    Logger.info("[Benchmark] Success counter: #{success_count}, Error counter: #{error_count}")

    # Collect results
    all_latencies = :ets.tab2list(latencies) |> Enum.map(fn {_, l} -> l end) |> Enum.sort()
    ets_count = length(all_latencies)
    Logger.info("[Benchmark] ETS entries: #{ets_count}")
    :ets.delete(latencies)

    total_blocks = ets_count
    total_samples = total_blocks * samples_per_block
    bytes_per_sample = 4

    num_channels = num_rigs * (num_rigs - 1)

    stats = %Stats{
      num_rigs: num_rigs,
      num_channels: num_channels,
      duration_sec: actual_duration_us / 1_000_000,
      total_blocks: total_blocks,
      total_samples: total_samples,
      blocks_per_sec: total_blocks / (actual_duration_us / 1_000_000),
      samples_per_sec: total_samples / (actual_duration_us / 1_000_000),
      bytes_per_sec: (total_samples * bytes_per_sample) / (actual_duration_us / 1_000_000),
      avg_latency_us: safe_avg(all_latencies),
      p99_latency_us: safe_percentile(all_latencies, 99),
      max_latency_us: safe_max(all_latencies),
      channel_count: MinutemodemSimnet.Physics.Nif.channel_count(),
      dropped_blocks: 0,  # TODO: track via t0 gaps
      errors: :counters.get(errors, 1)
    }

    # Cleanup
    MinutemodemSimnet.stop_epoch()
    cleanup_rigs(rigs)

    print_results(stats)
    stats
  end

  defp wait_for_no_epoch do
    case MinutemodemSimnet.Epoch.Store.current_epoch() do
      :error -> :ok
      {:ok, _} ->
        # Yield to scheduler, then poll again
        # Note: eParl doesn't provide epoch change notifications,
        # so polling is necessary here
        :erlang.yield()
        wait_for_no_epoch()
    end
  end

  defp wait_for_workers([]), do: :ok
  defp wait_for_workers(workers) do
    receive do
      {:worker_done, pid} ->
        remaining = Enum.reject(workers, fn {p, _ref} -> p == pid end)
        wait_for_workers(remaining)

      {:DOWN, ref, :process, pid, reason} ->
        if reason != :normal do
          Logger.warning("[Benchmark] Worker #{inspect(pid)} crashed: #{inspect(reason)}")
        end
        remaining = Enum.reject(workers, fn {_p, r} -> r == ref end)
        wait_for_workers(remaining)
    end
  end

  defp tx_loop_timed(rig, samples, samples_per_block, block_num, block_interval_us, deadline, latencies, errors, successes) do
    now = System.monotonic_time(:microsecond)

    if now >= deadline do
      # Log final iteration count
      require Logger
      Logger.info("[Benchmark] #{inspect(rig)} completed #{block_num - 1} iterations")
      :ok
    else
      t0 = block_num * samples_per_block

      tx_start = System.monotonic_time(:microsecond)
      result = MinutemodemSimnet.tx(rig, t0, samples)
      tx_end = System.monotonic_time(:microsecond)

      case result do
        :ok ->
          :counters.add(successes, 1, 1)
          latency = tx_end - tx_start
          :ets.insert(latencies, {rig, latency})

        {:error, reason} ->
          # Log first few errors to understand what's happening
          if block_num < 10 do
            require Logger
            Logger.warning("[Benchmark] TX error for #{inspect(rig)} block #{block_num}: #{inspect(reason)}")
          end
          :counters.add(errors, 1, 1)

        other ->
          # Unexpected result - log and count as error
          if block_num < 10 do
            require Logger
            Logger.error("[Benchmark] Unexpected TX result for #{inspect(rig)} block #{block_num}: #{inspect(other)}")
          end
          :counters.add(errors, 1, 1)
      end

      # No sleep - measure max throughput
      _ = block_interval_us

      tx_loop_timed(rig, samples, samples_per_block, block_num + 1, block_interval_us, deadline, latencies, errors, successes)
    end
  end

  defp setup_rigs(num_rigs) do
    rigs = for i <- 1..num_rigs do
      rig_id = :"bench_rig_#{i}"

      case MinutemodemSimnet.attach_rig(rig_id, %{
        sample_rates: [9600, 48000],
        block_ms: [1, 2, 5],
        representation: [:audio_f32]
      }) do
        {:ok, _} -> rig_id
        {:error, :already_attached} -> rig_id
      end
    end

    {:ok, rigs}
  end

  defp cleanup_rigs(rigs) do
    for rig <- rigs do
      MinutemodemSimnet.detach_rig(rig)
    end
    :ok
  end

  defp safe_avg([]), do: 0.0
  defp safe_avg(list), do: Enum.sum(list) / length(list)

  defp safe_percentile([], _p), do: 0
  defp safe_percentile(sorted_list, p) do
    idx = trunc(length(sorted_list) * p / 100)
    Enum.at(sorted_list, min(idx, length(sorted_list) - 1))
  end

  defp safe_max([]), do: 0
  defp safe_max(list), do: Enum.max(list)

  defp print_results(%Stats{} = s) do
    IO.puts("""

    ╔══════════════════════════════════════════════════════════════╗
    ║                    BENCHMARK RESULTS                         ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Configuration                                               ║
    ║    Rigs:           #{String.pad_leading("#{s.num_rigs}", 10)}                            ║
    ║    Channels:       #{String.pad_leading("#{s.num_channels}", 10)}  (full mesh)               ║
    ║    Duration:       #{String.pad_leading("#{Float.round(s.duration_sec, 2)}s", 10)}                            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Throughput                                                  ║
    ║    Blocks/sec:     #{String.pad_leading("#{trunc(s.blocks_per_sec)}", 10)}                            ║
    ║    Samples/sec:    #{String.pad_leading("#{trunc(s.samples_per_sec)}", 10)}                            ║
    ║    Bandwidth:      #{String.pad_leading(format_bandwidth(s.bytes_per_sec), 10)}                            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Latency (TX call duration)                                  ║
    ║    Average:        #{String.pad_leading("#{trunc(s.avg_latency_us)} µs", 10)}                            ║
    ║    P99:            #{String.pad_leading("#{s.p99_latency_us} µs", 10)}                            ║
    ║    Max:            #{String.pad_leading("#{s.max_latency_us} µs", 10)}                            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Resources                                                   ║
    ║    NIF Channels:   #{String.pad_leading("#{s.channel_count}", 10)}                            ║
    ║    Errors:         #{String.pad_leading("#{s.errors}", 10)}                            ║
    ╚══════════════════════════════════════════════════════════════╝
    """)
  end

  defp format_bandwidth(bytes_per_sec) when bytes_per_sec < 1024, do: "#{trunc(bytes_per_sec)} B/s"
  defp format_bandwidth(bytes_per_sec) when bytes_per_sec < 1024 * 1024, do: "#{Float.round(bytes_per_sec / 1024, 1)} KB/s"
  defp format_bandwidth(bytes_per_sec), do: "#{Float.round(bytes_per_sec / (1024 * 1024), 2)} MB/s"
end
