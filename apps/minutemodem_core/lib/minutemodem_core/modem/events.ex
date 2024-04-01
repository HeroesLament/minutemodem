defmodule MinuteModemCore.Modem.Events do
  @moduledoc """
  Pub/sub event bus for modem events.

  Interface adapters (110D-A, KISS) subscribe to receive modem events
  and translate them into their respective wire formats.

  ## Event Types

  TX events:
  - `{:modem, {:tx_status, status_map}}` - TX state or queue changed
  - `{:modem, :tx_underrun}` - TX buffer starved

  RX events:
  - `{:modem, {:rx_carrier, :detected | :lost | :receiving, params}}` - Carrier state
  - `{:modem, {:rx_data, data, order}}` - Received data packet

  ## Usage

      # Subscribe to all modem events
      Events.subscribe(rig_id, self())

      # In your handle_info
      def handle_info({:modem, {:tx_status, status}}, state) do
        # Translate to 110D-A TRANSMIT_STATUS packet
        ...
      end

      def handle_info({:modem, {:rx_data, data, order}}, state) do
        # Translate to 110D-A DATA packet or KISS frame
        ...
      end
  """

  use GenServer

  require Logger

  defstruct [
    :rig_id,
    :subscribers  # MapSet of {pid, filter}
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :events}}}
  end

  @doc """
  Subscribe to modem events.

  Options:
  - `:tx` - Only TX events
  - `:rx` - Only RX events
  - `:all` - All events (default)
  """
  def subscribe(rig_id, pid, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    GenServer.call(via(rig_id), {:subscribe, pid, filter})
  end

  @doc """
  Unsubscribe from modem events.
  """
  def unsubscribe(rig_id, pid) do
    GenServer.call(via(rig_id), {:unsubscribe, pid})
  end

  @doc """
  Broadcast an event to all subscribers.

  Called by TxFSM, RxFSM, etc.
  """
  def broadcast(rig_id, event) do
    GenServer.cast(via(rig_id), {:broadcast, event})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    state = %__MODULE__{
      rig_id: rig_id,
      subscribers: MapSet.new()
    }

    Logger.debug("[Modem.Events] Started for rig #{rig_id}")

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid, filter}, _from, state) do
    # Monitor the subscriber so we can clean up if they crash
    Process.monitor(pid)

    new_subscribers = MapSet.put(state.subscribers, {pid, filter})
    Logger.debug("[Modem.Events] #{inspect(pid)} subscribed with filter #{filter}")

    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers =
      state.subscribers
      |> Enum.reject(fn {p, _} -> p == pid end)
      |> MapSet.new()

    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:broadcast, event}, state) do
    event_type = classify_event(event)

    state.subscribers
    |> Enum.each(fn {pid, filter} ->
      if matches_filter?(event_type, filter) do
        send(pid, event)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Subscriber died, remove them
    new_subscribers =
      state.subscribers
      |> Enum.reject(fn {p, _} -> p == pid end)
      |> MapSet.new()

    {:noreply, %{state | subscribers: new_subscribers}}
  end

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp classify_event({:modem, {:tx_status, _}}), do: :tx
  defp classify_event({:modem, {:tx_audio, _}}), do: :tx
  defp classify_event({:modem, :tx_underrun}), do: :tx
  defp classify_event({:modem, {:rx_carrier, _, _}}), do: :rx
  defp classify_event({:modem, {:rx_data, _, _}}), do: :rx
  defp classify_event(_), do: :other

  defp matches_filter?(_event_type, :all), do: true
  defp matches_filter?(event_type, filter), do: event_type == filter
end
