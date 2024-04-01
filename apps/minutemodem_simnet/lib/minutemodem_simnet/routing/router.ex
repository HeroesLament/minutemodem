defmodule MinutemodemSimnet.Routing.Router do
  @moduledoc """
  Routes TX blocks to ChannelFSMs and delivers RX blocks to rigs.

  This is a GenServer that maintains persistent channel caches across
  RPC calls. Without this, each RPC call would spawn a new process
  with an empty cache, creating new channels on every transmission.

  When a rig transmits:
  1. Router looks up all other rigs (potential receivers)
  2. For each receiver, computes propagation parameters from physical config
  3. Ensures a ChannelFSM exists with appropriate parameters
  4. Forwards the TX block to each ChannelFSM
  5. ChannelFSMs apply physics and deliver RX to receivers

  This creates the synthetic mesh of point-to-point channels.
  """

  use GenServer

  require Logger

  alias MinutemodemSimnet.Channel
  alias MinutemodemSimnet.Rig
  alias MinutemodemSimnet.Epoch
  alias MinutemodemSimnet.Group.Environment

  @type tx_opts :: [freq_hz: pos_integer()]
  @type tx_result :: :ok | {:error, term()}

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Transmits a block from a rig.

  Fans out to all ChannelFSMs for links from this rig.
  Creates channels lazily if they don't exist.

  ## Options

    * `:freq_hz` - Transmit frequency in Hz (required for propagation calculation)

  ## Example

      Router.tx(:station_a, 0, samples, freq_hz: 7_300_000)
  """
  def tx(from_rig, t0, samples, opts \\ []) do
    GenServer.call(__MODULE__, {:tx, from_rig, t0, samples, opts})
  end

  @doc """
  Clears all cached data.
  Call this when epoch changes or between benchmark runs.
  """
  def invalidate_cache do
    GenServer.cast(__MODULE__, :invalidate_cache)
  end

  # --- GenServer Implementation ---

  defstruct [
    :epoch,
    :rigs,
    :destinations,
    :channels
  ]

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      epoch: nil,
      rigs: [],
      destinations: %{},
      channels: %{}
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:tx, from_rig, t0, samples, opts}, _from, state) do
    freq_hz = Keyword.get(opts, :freq_hz)

    case validate_tx(from_rig, state) do
      {:ok, destinations, new_state} ->
        {result, final_state} =
          Enum.reduce(destinations, {:ok, new_state}, fn to_rig, {acc_result, acc_state} ->
            case ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, acc_state) do
              {:ok, updated_state} ->
                {acc_result, updated_state}
              {{:error, _} = error, updated_state} ->
                {error, updated_state}
            end
          end)

        {:reply, result, final_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast(:invalidate_cache, _state) do
    {:noreply, %__MODULE__{
      epoch: nil,
      rigs: [],
      destinations: %{},
      channels: %{}
    }}
  end

  # --- Internal ---

  defp validate_tx(from_rig, state) do
    case state.epoch do
      nil ->
        # Cold start - fetch and cache
        refresh_cache_and_validate(from_rig, state)

      %{metadata: %{epoch_id: _epoch_id}} ->
        # Cache is warm - use it directly
        get_destinations(from_rig, state)

      _other ->
        # Unexpected cache format - refresh
        refresh_cache_and_validate(from_rig, state)
    end
  end

  defp refresh_cache_and_validate(from_rig, state) do
    with {:ok, epoch} <- Epoch.Store.current_epoch(),
         {:ok, _attachment} <- Rig.Store.get(from_rig) do
      # Cache rig list and compute destinations
      all_rigs = Rig.Store.list_all() |> Enum.map(fn {id, _} -> id end)
      destinations = Enum.reject(all_rigs, fn id -> id == from_rig end)

      new_state = %{state |
        epoch: epoch,
        rigs: all_rigs,
        destinations: Map.put(state.destinations, from_rig, destinations)
      }

      {:ok, destinations, new_state}
    else
      :error -> {:error, :no_active_epoch}
      {:error, _} = error -> error
    end
  end

  defp get_destinations(from_rig, state) do
    case Map.get(state.destinations, from_rig) do
      nil ->
        # This rig not cached yet - compute from cached rig list
        destinations = Enum.reject(state.rigs, fn id -> id == from_rig end)
        new_state = %{state | destinations: Map.put(state.destinations, from_rig, destinations)}
        {:ok, destinations, new_state}

      destinations ->
        {:ok, destinations, state}
    end
  end

  defp ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, state) do
    # Check for skip zone before creating/using channel
    case check_propagation(from_rig, to_rig, freq_hz) do
      {:ok, :skip} ->
        # No propagation in skip zone - silently drop
        {:ok, state}

      {:ok, _regime} ->
        # Propagation possible - proceed with channel
        do_ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, state)

      {:error, _reason} ->
        # Can't determine propagation - proceed anyway with defaults
        do_ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, state)
    end
  end

  defp check_propagation(from_rig, to_rig, freq_hz) when is_integer(freq_hz) do
    case Environment.compute_channel_params(from_rig, to_rig, freq_hz) do
      {:ok, %{regime: :skip}} -> {:ok, :skip}
      {:ok, %{regime: regime}} -> {:ok, regime}
      {:ok, _params} -> {:ok, :unknown}
      error -> error
    end
  end

  defp check_propagation(_from_rig, _to_rig, nil) do
    # No frequency specified - allow propagation with defaults
    {:ok, :unknown}
  end

  defp do_ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, state) do
    # Cache key includes frequency since params depend on it
    cache_key = {from_rig, to_rig, freq_hz}

    case get_cached_channel(cache_key, state) do
      {:ok, pid} ->
        case do_process_tx(pid, t0, samples) do
          :ok ->
            {:ok, state}
          {:error, _} = err ->
            {err, state}
          # Handle dead pid - remove from cache and retry
          {:exit, _reason} ->
            new_state = invalidate_channel(cache_key, state)
            do_ensure_channel_and_tx(from_rig, to_rig, t0, samples, freq_hz, new_state)
        end

      :miss ->
        # Not in cache, create the channel
        Logger.debug("[Router] Creating channel #{inspect(from_rig)} -> #{inspect(to_rig)} @ #{freq_hz} Hz")
        case create_channel(from_rig, to_rig, freq_hz) do
          {:ok, pid} when is_pid(pid) ->
            # Cache the pid immediately
            new_state = cache_channel(cache_key, pid, state)
            Logger.debug("[Router] Channel created with pid #{inspect(pid)}, cached")
            result = do_process_tx(pid, t0, samples)
            case result do
              :ok -> {:ok, new_state}
              {:error, _} = err -> {err, new_state}
              {:exit, reason} -> {{:error, {:channel_died, reason}}, new_state}
            end

          {:error, {:already_started, pid}} ->
            new_state = cache_channel(cache_key, pid, state)
            result = do_process_tx(pid, t0, samples)
            case result do
              :ok -> {:ok, new_state}
              {:error, _} = err -> {err, new_state}
              {:exit, reason} -> {{:error, {:channel_died, reason}}, new_state}
            end

          {:error, reason} ->
            Logger.error("[Router] Failed to create channel: #{inspect(reason)}")
            {{:error, {:channel_creation_failed, reason}}, state}
        end
    end
  end

  defp get_cached_channel(cache_key, state) do
    case Map.get(state.channels, cache_key) do
      nil -> :miss
      pid when is_pid(pid) ->
        # Verify pid is still alive
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :miss
        end
    end
  end

  defp cache_channel(cache_key, pid, state) do
    %{state | channels: Map.put(state.channels, cache_key, pid)}
  end

  defp invalidate_channel(cache_key, state) do
    %{state | channels: Map.delete(state.channels, cache_key)}
  end

  defp do_process_tx(pid, t0, samples) do
    try do
      GenStateMachine.call(pid, {:tx_block, t0, samples})
    catch
      :exit, reason -> {:exit, reason}
    end
  end

  defp create_channel(from_rig, to_rig, freq_hz) do
    params = build_channel_params(from_rig, to_rig, freq_hz)
    Channel.Supervisor.start_channel(from_rig, to_rig, params)
  end

  defp build_channel_params(from_rig, to_rig, freq_hz) do
    base_params = %{
      from_rig: from_rig,
      to_rig: to_rig,
      freq_hz: freq_hz
    }

    # Try to compute propagation-based parameters
    case Environment.compute_channel_params(from_rig, to_rig, freq_hz) do
      {:ok, env_params} ->
        Map.merge(base_params, env_params)

      {:error, _reason} ->
        # Fall back to defaults if we can't compute
        Map.merge(base_params, %{
          delay_spread_ms: 2.0,
          doppler_bandwidth_hz: 1.0,
          snr_db: 15.0
        })
    end
  end
end
