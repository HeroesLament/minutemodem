defmodule MinuteModemCore.Stack.Supervisor do
  use Supervisor

  def start_link(spec) do
    Supervisor.start_link(__MODULE__, spec)
  end

  @impl true
  def init(%{profile: :simulator} = spec) do
    children = [
      {MinuteModemCore.Stack.Simulator, spec}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
