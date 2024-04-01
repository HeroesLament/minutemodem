defmodule MinuteModemCore.Interface.MIL110D do
  @moduledoc """
  MIL-STD-188-110D Appendix A DTE Interface.

  Implements the TCP socket interface (TDSI) and optional UDP socket
  interface (UDSI) for DTE-to-modem communication.

  ## Architecture

      External DTE (JITC software, etc.)
                │
                ▼ TCP (port 3000 default)
      ┌─────────────────────────────────┐
      │     MIL110D.SessionFSM          │ ◄── CONNECT/PROBE/keepalive
      │         │                       │
      │    ┌────┴────┐                  │
      │    ▼         ▼                  │
      │ TxAdapter  RxAdapter            │ ◄── Packet parsing/building
      │    │         │                  │
      └────┼─────────┼──────────────────┘
           │         │
           ▼         ▼
        Modem.TxFSM  Modem.RxFSM        (transport-agnostic core)

  ## Protocol

  - TCP connection with explicit handshake (CONNECT/CONNECT_ACK)
  - CONNECTION_PROBE for RTT measurement
  - DATA packets with payload commands
  - 2-second keepalive, 30-second timeout
  - Optional UDP data plane for high-latency networks

  ## Usage

      # Start interface for a rig
      {:ok, _pid} = MIL110D.start_link(rig_id: rig_id, port: 3000)

      # Interface subscribes to modem events and translates them to packets
      # External DTEs connect via TCP and send/receive per Appendix A
  """

  alias MinuteModemCore.Interface.MIL110D.Supervisor, as: MIL110DSupervisor

  defdelegate start_link(opts), to: MIL110DSupervisor
  defdelegate child_spec(opts), to: MIL110DSupervisor

  @doc """
  Get interface status.
  """
  def status(rig_id) do
    # TODO: Query session FSM
    {:ok, %{rig_id: rig_id, connected: false}}
  end
end
