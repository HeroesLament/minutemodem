defmodule MinuteModemCore.Modem.Arbiter do
  @moduledoc """
  Half-duplex arbitration between TX and RX.

  Implements the half-duplex coordination logic from MIL-STD-188-110D
  Appendix A sections A.5.1.2.7.1 and A.5.1.2.7.2.

  ## Duplex Modes

  - `:full_duplex` - TX and RX operate independently
  - `:half_duplex_tx_master` - TX takes priority, aborts RX when starting
  - `:half_duplex_rx_master` - RX takes priority, TX defers until RX complete

  ## TX Master Behavior

  When TX requests to start and RX is active:
  - TX is allowed to proceed
  - RX is forcibly aborted (RxFSM receives abort signal)
  - RX emits LAST packet and transitions to NO_CARRIER

  ## RX Master Behavior

  When TX requests to start and RX is active:
  - TX ARM is allowed (queues can fill)
  - TX START is blocked (returns :port_not_ready)
  - When RX completes, TX is notified (:port_ready)
  - TX can then START

  The arbiter tracks:
  - Current duplex mode
  - RX active state
  - TX armed/waiting state
  """

  use GenServer

  require Logger

  defstruct [
    :rig_id,
    :mode,           # :full_duplex | :half_duplex_tx_master | :half_duplex_rx_master
    :rx_active,      # boolean - is RX in carrier_detected or receiving?
    :tx_armed,       # boolean - has TX requested to start?
    :tx_waiting_pid  # pid waiting for port_ready notification
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :arbiter}}}
  end

  @doc """
  Set the duplex mode.
  """
  def set_mode(server, mode) when mode in [:full_duplex, :half_duplex_tx_master, :half_duplex_rx_master] do
    GenServer.call(server, {:set_mode, mode})
  end

  @doc """
  TX requests permission to transmit.

  Returns:
  - `:ok` - Proceed with transmission
  - `:port_not_ready` - Armed but cannot start yet (half-duplex RX active)
  - `{:error, reason}` - Cannot arm
  """
  def request_tx(server) do
    GenServer.call(server, :request_tx)
  end

  @doc """
  TX releases its hold (transmission complete or aborted).
  """
  def release_tx(server) do
    GenServer.cast(server, :release_tx)
  end

  @doc """
  RX notifies that it has become active (carrier detected).
  """
  def rx_active(server) do
    GenServer.cast(server, :rx_active)
  end

  @doc """
  RX notifies that it has become idle (no carrier).
  """
  def rx_idle(server) do
    GenServer.cast(server, :rx_idle)
  end

  @doc """
  Get current arbiter state (for debugging).
  """
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    mode = Keyword.get(opts, :mode, :full_duplex)

    state = %__MODULE__{
      rig_id: rig_id,
      mode: mode,
      rx_active: false,
      tx_armed: false,
      tx_waiting_pid: nil
    }

    Logger.info("[Modem.Arbiter] Started for rig #{rig_id}, mode=#{mode}")

    {:ok, state}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) do
    Logger.info("[Modem.Arbiter] Mode changed to #{mode} for rig #{state.rig_id}")
    {:reply, :ok, %{state | mode: mode}}
  end

  @impl true
  def handle_call(:request_tx, {pid, _}, state) do
    case arbitrate_tx_request(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:port_not_ready, new_state} ->
        # Track who's waiting for notification
        {:reply, :port_not_ready, %{new_state | tx_waiting_pid: pid}}

      {:abort_rx, new_state} ->
        # TX master mode - abort RX and proceed
        abort_rx(state.rig_id)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_cast(:release_tx, state) do
    {:noreply, %{state | tx_armed: false, tx_waiting_pid: nil}}
  end

  @impl true
  def handle_cast(:rx_active, state) do
    new_state = %{state | rx_active: true}

    # In TX master mode, if TX is armed and waiting, we might need to abort RX
    # But actually, TX master means TX wins when it STARTs, not when RX activates
    # So we just track state here

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:rx_idle, state) do
    new_state = %{state | rx_active: false}

    # If TX was waiting, notify it
    if state.tx_waiting_pid do
      send(state.tx_waiting_pid, {:port_ready})
      Logger.debug("[Modem.Arbiter] Notified TX that port is ready")
    end

    {:noreply, %{new_state | tx_waiting_pid: nil}}
  end

  # ============================================================================
  # Internal logic
  # ============================================================================

  defp arbitrate_tx_request(state) do
    case state.mode do
      :full_duplex ->
        # Always allow
        {:ok, %{state | tx_armed: true}}

      :half_duplex_tx_master ->
        if state.rx_active do
          # TX master: abort RX and proceed
          {:abort_rx, %{state | tx_armed: true, rx_active: false}}
        else
          {:ok, %{state | tx_armed: true}}
        end

      :half_duplex_rx_master ->
        if state.rx_active do
          # RX master: TX must wait
          {:port_not_ready, %{state | tx_armed: true}}
        else
          {:ok, %{state | tx_armed: true}}
        end
    end
  end

  defp abort_rx(rig_id) do
    # Send abort to RxFSM
    rx_server = {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :rx}}}

    case GenServer.whereis(rx_server) do
      nil ->
        Logger.warning("[Modem.Arbiter] Cannot abort RX - RxFSM not found")

      _pid ->
        MinuteModemCore.Modem.RxFSM.abort(rx_server)
        Logger.debug("[Modem.Arbiter] Aborted RX for TX master priority")
    end
  end
end
