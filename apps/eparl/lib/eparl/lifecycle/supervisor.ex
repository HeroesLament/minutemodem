# lifecycle/supervisor.ex
defmodule Eparl.Lifecycle.Supervisor do
  @moduledoc """
  Main supervision tree for eparl.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    command_module = Keyword.fetch!(opts, :command_module)
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    initial_state = Keyword.get(opts, :initial_state, %{})
    replica_id = Keyword.get(opts, :replica_id, node())

    children = [
      Eparl.Boundaries.Membership,
      {Eparl.Boundaries.Executor, command_module: command_module, initial_state: initial_state},
      {Eparl.Boundaries.Replica, command_module: command_module, cluster_size: cluster_size, replica_id: replica_id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
