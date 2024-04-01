defmodule MinuteModemCore.Interface.MIL110D.Supervisor do
  @moduledoc """
  Supervisor for the MIL-STD-188-110D Appendix A interface.

  Manages:
  - TCP listener (accepts one DTE connection at a time)
  - SessionFSM (protocol state machine per connection)
  - TxAdapter (translates DTE packets → Modem API)
  - RxAdapter (translates Modem events → DTE packets)
  - Optional UDP data plane
  """

  use Supervisor

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    Supervisor.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Interface.Registry, {rig_id, :mil110d}}}
  end

  def child_spec(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    %{
      id: {__MODULE__, rig_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    port = Keyword.get(opts, :port, 3000)

    children = [
      # TCP listener - accepts connections and spawns session
      {MinuteModemCore.Interface.MIL110D.Listener,
       rig_id: rig_id,
       port: port}
    ]

    # Note: SessionFSM is started dynamically when a DTE connects
    # and terminated when the connection closes

    Supervisor.init(children, strategy: :one_for_one)
  end
end
