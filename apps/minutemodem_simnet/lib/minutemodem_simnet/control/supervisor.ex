defmodule MinutemodemSimnet.Control.Supervisor do
  @moduledoc """
  Supervises the Highlander-managed control server singleton.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Highlander, MinutemodemSimnet.Control.Server}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
