defmodule MinuteModemCore.Modem do
  @moduledoc """
  Transport-agnostic modem API.

  This module defines the semantic interface between external DTE interfaces
  (110D-A TCP, KISS, direct Elixir calls) and the underlying waveform/PHY layer.

  The modem does not know or care about:
  - TCP packets or KISS framing
  - CRCs or preambles
  - Socket management

  It only understands:
  - TX: arm, start, data, last, abort
  - RX: carrier detected, data, abort
  - Status: rates, blocking factors, queue depths

  ## Architecture

      Interface Layer (110D-A / KISS / Direct)
                      │
                      ▼
              Modem (this module)
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
       TxFSM      RxFSM      Arbiter
          │           │           │
          └───────────┴───────────┘
                      │
                      ▼
              PHY (ALE.Transmitter / ALE.Receiver)
  """

  alias MinuteModemCore.Modem.{Supervisor, TxFSM, RxFSM, Arbiter, Events}

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @doc """
  Start the modem subsystem for a rig.

  Called by Rig.Instance when the rig starts.
  """
  def start_link(opts) do
    Supervisor.start_link(opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:rig_id]},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  # ============================================================================
  # TX API (called by interface adapters)
  # ============================================================================

  @doc """
  Arm the transmitter.

  Prepares TX queues for data. Must be called before `start_tx/1`.
  In half-duplex RX-master mode, this may return `:port_not_ready`
  until RX completes.

  Returns:
  - `{:ok, :armed}` - Queues armed, ready for prefill
  - `{:ok, :armed_port_not_ready}` - Armed but waiting for RX to complete
  - `{:error, :not_flushed}` - TX not in flushed state
  """
  @spec arm_tx(rig_id :: binary()) :: {:ok, atom()} | {:error, atom()}
  def arm_tx(rig_id) do
    TxFSM.arm(via_tx(rig_id))
  end

  @doc """
  Send TX data.

  Data is queued for transmission. The `order` option indicates packet position:
  - `:first` - First packet of a multi-packet transfer
  - `:continuation` - Middle packet
  - `:last` - Final packet
  - `:first_and_last` - Single-packet transfer

  Returns:
  - `:ok` - Data queued
  - `{:error, :not_armed}` - Must arm first
  - `{:error, :queue_full}` - Backpressure, wait for space
  """
  @spec tx_data(rig_id :: binary(), data :: binary(), opts :: keyword()) ::
          :ok | {:error, atom()}
  def tx_data(rig_id, data, opts \\ []) do
    order = Keyword.get(opts, :order, :continuation)
    TxFSM.data(via_tx(rig_id), data, order)
  end

  @doc """
  Start transmission.

  Call after arming and prefilling with at least 3 blocking factors of data
  (unless sending FIRST_AND_LAST or LAST).

  In half-duplex RX-master mode, this may fail if RX is active.

  Returns:
  - `{:ok, :started}` - Transmission begun
  - `{:error, :not_armed}` - Must arm first
  - `{:error, :port_not_ready}` - Wait and retry (half-duplex)
  - `{:error, :insufficient_prefill}` - Need more data first
  """
  @spec start_tx(rig_id :: binary()) :: {:ok, :started} | {:error, atom()}
  def start_tx(rig_id) do
    TxFSM.start(via_tx(rig_id))
  end

  @doc """
  Abort current transmission.

  Forces immediate transition to draining/flushed state.
  """
  @spec abort_tx(rig_id :: binary()) :: :ok
  def abort_tx(rig_id) do
    TxFSM.abort(via_tx(rig_id))
  end

  @doc """
  Request current TX status.

  Returns a map with:
  - `:state` - Current FSM state
  - `:queued_bytes` - Bytes waiting in queue
  - `:free_bytes` - Space available
  - `:data_rate` - Current TX rate (bps)
  - `:blocking_factor` - Interleaver chunk size (bits)
  """
  @spec tx_status(rig_id :: binary()) :: map()
  def tx_status(rig_id) do
    TxFSM.status(via_tx(rig_id))
  end

  # ============================================================================
  # RX API (called by interface adapters)
  # ============================================================================

  @doc """
  Abort current reception.

  Forces modem to abandon sync and return to NO_CARRIER state.
  A LAST packet will be emitted to close any open data stream.
  """
  @spec abort_rx(rig_id :: binary()) :: :ok
  def abort_rx(rig_id) do
    RxFSM.abort(via_rx(rig_id))
  end

  @doc """
  Request current RX status.

  Returns a map with:
  - `:state` - Current FSM state (:no_carrier, :carrier_detected, :receiving)
  - `:data_rate` - Detected RX rate (bps), 0 if no carrier
  - `:blocking_factor` - Detected blocking factor (bits), 0 if no carrier
  """
  @spec rx_status(rig_id :: binary()) :: map()
  def rx_status(rig_id) do
    RxFSM.status(via_rx(rig_id))
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Set TX waveform parameters.

  Called during modem configuration to set waveform parameters.
  These are reported to DTEs and used for prefill calculations.
  """
  @spec set_tx_params(rig_id :: binary(), waveform :: pos_integer(), bw_khz :: pos_integer(), interleaver :: atom()) ::
          :ok
  def set_tx_params(rig_id, waveform, bw_khz, interleaver) do
    TxFSM.set_params(via_tx(rig_id), waveform, bw_khz, interleaver)
  end

  @doc """
  Configure duplex mode.

  - `:full_duplex` - TX and RX operate independently
  - `:half_duplex_tx_master` - TX takes priority, aborts RX
  - `:half_duplex_rx_master` - RX takes priority, defers TX start
  """
  @spec set_duplex_mode(rig_id :: binary(), mode :: atom()) :: :ok
  def set_duplex_mode(rig_id, mode) do
    Arbiter.set_mode(via_arbiter(rig_id), mode)
  end

  # ============================================================================
  # Event Subscription (for interface adapters)
  # ============================================================================

  @doc """
  Subscribe to modem events.

  The caller will receive messages:
  - `{:modem_tx_status, status_map}` - TX state changed
  - `{:modem_rx_carrier, :detected | :lost, params}` - Carrier state
  - `{:modem_rx_data, data, order}` - Received data
  - `{:modem_tx_underrun}` - TX buffer underrun

  Options:
  - `:tx` - Subscribe to TX events
  - `:rx` - Subscribe to RX events
  - `:all` - Subscribe to everything (default)
  """
  @spec subscribe(rig_id :: binary(), opts :: keyword()) :: :ok
  def subscribe(rig_id, opts \\ []) do
    Events.subscribe(rig_id, self(), opts)
  end

  @doc """
  Unsubscribe from modem events.
  """
  @spec unsubscribe(rig_id :: binary()) :: :ok
  def unsubscribe(rig_id) do
    Events.unsubscribe(rig_id, self())
  end

  # ============================================================================
  # Registry helpers
  # ============================================================================

  defp via_tx(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :tx}}}
  end

  defp via_rx(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :rx}}}
  end

  defp via_arbiter(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :arbiter}}}
  end
end
