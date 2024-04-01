defmodule MinutemodemSimnet.Routing.RxRegistry do
  @moduledoc """
  ETS-based registry for RX subscriptions.

  Allows rigs to subscribe to incoming RX blocks without needing
  to know about individual channels. When a channel delivers an RX
  block, it looks up the subscription here.

  ## Usage from minutemodem_core

      # Subscribe to all RX for a rig
      MinutemodemSimnet.subscribe_rx(:my_rig, self())

      # Receive messages
      receive do
        {:simnet_rx, from_rig, t0, samples, freq_hz, metadata} ->
          # Handle received block
      end

      # Or with a callback function
      MinutemodemSimnet.subscribe_rx(:my_rig, fn msg ->
        handle_rx(msg)
      end)
  """

  use GenServer

  @table __MODULE__

  # Client API

  @doc """
  Subscribes to RX blocks destined for a rig.

  ## Subscription types

    * `pid` - Messages sent as `{:simnet_rx, from_rig, t0, samples, freq_hz, metadata}`
    * `fun/1` - Called with `{:simnet_rx, from_rig, t0, samples, freq_hz, metadata}`

  Only one subscription per rig is allowed. New subscriptions replace old ones.
  """
  @spec subscribe(atom() | String.t(), pid() | (term() -> any())) :: :ok
  def subscribe(rig_id, subscriber) when is_atom(rig_id) or is_binary(rig_id) do
    # Validate subscriber
    case subscriber do
      pid when is_pid(pid) -> :ok
      fun when is_function(fun, 1) -> :ok
      _ -> raise ArgumentError, "subscriber must be a pid or function/1"
    end

    # Monitor pids so we can clean up on crash
    if is_pid(subscriber) do
      GenServer.call(__MODULE__, {:subscribe_with_monitor, rig_id, subscriber})
    else
      :ets.insert(@table, {rig_id, subscriber})
      :ok
    end
  end

  @doc """
  Unsubscribes from RX blocks for a rig.
  """
  @spec unsubscribe(atom() | String.t()) :: :ok
  def unsubscribe(rig_id) when is_atom(rig_id) or is_binary(rig_id) do
    GenServer.call(__MODULE__, {:unsubscribe, rig_id})
  end

  @doc """
  Delivers an RX block to the subscriber for a rig.

  Called by ChannelFSM when processing TX blocks.
  Returns `:ok` if delivered, `:no_subscriber` if no subscription exists.
  """
  @spec deliver(atom(), atom(), non_neg_integer(), binary(), pos_integer() | nil, map()) :: :ok | :no_subscriber
  def deliver(to_rig, from_rig, t0, samples, freq_hz, metadata \\ %{}) do
    case :ets.lookup(@table, to_rig) do
      [{^to_rig, subscriber}] ->
        msg = {:simnet_rx, from_rig, t0, samples, freq_hz, metadata}

        case subscriber do
          pid when is_pid(pid) ->
            send(pid, msg)
            :ok

          fun when is_function(fun, 1) ->
            # Spawn to avoid blocking the channel FSM
            spawn(fn -> fun.(msg) end)
            :ok
        end

      [] ->
        :no_subscriber
    end
  end

  @doc """
  Checks if a rig has an active subscription.
  """
  @spec subscribed?(atom()) :: boolean()
  def subscribed?(rig_id) do
    :ets.member(@table, rig_id)
  end

  @doc """
  Lists all active subscriptions.
  """
  @spec list_subscriptions() :: [{atom(), pid() | function()}]
  def list_subscriptions do
    :ets.tab2list(@table)
  end

  # Server

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Create ETS table for fast lookups from channel FSMs
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe_with_monitor, rig_id, pid}, _from, state) do
    # Clean up old monitor if exists
    state = cleanup_monitor(state, rig_id)

    # Monitor the new subscriber
    ref = Process.monitor(pid)

    # Insert subscription
    :ets.insert(@table, {rig_id, pid})

    new_state = %{state | monitors: Map.put(state.monitors, ref, rig_id)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, rig_id}, _from, state) do
    state = cleanup_monitor(state, rig_id)
    :ets.delete(@table, rig_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      rig_id ->
        :ets.delete(@table, rig_id)
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
    end
  end

  defp cleanup_monitor(state, rig_id) do
    # Find and demonitor any existing subscription for this rig
    case Enum.find(state.monitors, fn {_ref, rid} -> rid == rig_id end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref)}

      nil ->
        state
    end
  end
end
