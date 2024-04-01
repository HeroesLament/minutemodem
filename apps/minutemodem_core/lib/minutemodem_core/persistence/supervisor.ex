defmodule MinuteModemCore.Rig.Supervisor do
  use Supervisor

  def start_link(spec) do
    Supervisor.start_link(__MODULE__, spec)
  end

  @impl true
  def init(%{id: _id, profile: :simulator} = spec) do
    children = [
      {MinuteModemCore.Rig.Control, spec},
      {MinuteModemCore.Stack.Supervisor, spec}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
