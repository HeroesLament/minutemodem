defmodule MinuteModemCore.Stack.Simulator do
  use Supervisor

  def start_link(spec) do
    Supervisor.start_link(__MODULE__, spec)
  end

  @impl true
  def init(spec) do
    children = [
      {MinuteModemCore.Simulator.Source, spec},
      MinuteModemCore.Simulator.RX.Dispatcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
