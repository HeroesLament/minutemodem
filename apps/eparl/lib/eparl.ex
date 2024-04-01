# lib/eparl.ex
defmodule Eparl do
  @moduledoc """
  Eparl - Egalitarian Parliament.

  An Elixir implementation of ePaxos (Egalitarian Paxos) for replicated
  state machines without a leader bottleneck.

  ## Usage

      # Define your command module
      defmodule MyApp.KVCommand do
        @behaviour Eparl.Data.Command

        @impl true
        def interferes?({:put, key, _}, {:put, key2, _}), do: key == key2
        def interferes?({:get, key}, {:put, key2, _}), do: key == key2
        def interferes?(_, _), do: false

        @impl true
        def execute({:put, key, value}, state), do: {:ok, Map.put(state, key, value)}
        def execute({:get, key}, state), do: {Map.get(state, key), state}
      end

      # Start eparl with fixed cluster size
      Eparl.start_link(command_module: MyApp.KVCommand, cluster_size: 3)

      # Propose commands
      {:ok, result} = Eparl.propose({:put, "name", "alice"})
      {:ok, "alice"} = Eparl.propose({:get, "name"})

  ## References

  - "There is more consensus in Egalitarian parliaments" - ACM SOSP 2013
  - "Achieving the Full Potential of State Machine Replication" - Microsoft Research
  """

  @doc """
  Start the eparl supervision tree.

  ## Options

  - `:command_module` (required) - Module implementing `Eparl.Data.Command`
  - `:cluster_size` (required) - Fixed number of replicas in the cluster (for quorum calculation)
  - `:initial_state` - Initial state for the replicated state machine (default: `%{}`)
  - `:replica_id` - Identifier for this replica (default: `node()`)
  """
  def start_link(opts) do
    Eparl.Lifecycle.Supervisor.start_link(opts)
  end

  @doc """
  Propose a command for consensus.

  Blocks until the command is committed and executed, then returns the result.

  Returns:
  - `{:ok, result}` - Command was committed and executed
  - `{:error, :no_quorum, info}` - Not enough replicas available
  - `{:error, :recovery_timeout}` - Recovery failed
  """
  def propose(command) do
    Eparl.Boundaries.Replica.propose(command)
  end

  @doc """
  Get cluster information.
  """
  def info do
    %{
      replicas: Eparl.Boundaries.Membership.replicas(),
      cluster_size: Eparl.Boundaries.Membership.cluster_size()
    }
  end

  @doc """
  Get all replica pids in the cluster.
  """
  def replicas do
    Eparl.Boundaries.Membership.replicas()
  end
end
