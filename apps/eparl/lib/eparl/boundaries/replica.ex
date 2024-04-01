defmodule Eparl.Boundaries.Replica do
  @moduledoc """
  Main replica GenServer that coordinates ePaxos consensus.

  Handles:
  - Client proposals
  - Protocol message routing
  - Instance storage (ETS)
  - FSM lifecycle management
  - Recovery of missing instances
  """

  use GenServer
  require Logger

  alias Eparl.Boundaries.{InstanceFSM, Membership, Executor}
  alias Eparl.Core.{Consensus, Quorum}
  alias Eparl.Data.{Instance, Ballot}

  defstruct [
    :table,
    :command_module,
    :cluster_size,
    :replica_id,
    instances: %{}
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def propose(command, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:propose, command}, timeout)
  end

  def info do
    GenServer.call(__MODULE__, :info)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    command_module = Keyword.fetch!(opts, :command_module)
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    replica_id = Keyword.get(opts, :replica_id, node())

    table = :ets.new(:eparl_instances, [:set, :public, read_concurrency: true])

    state = %__MODULE__{
      table: table,
      command_module: command_module,
      cluster_size: cluster_size,
      replica_id: replica_id
    }

    # Join the cluster
    Membership.join(self())

    # Sync with peers after a short delay (let pg propagate)
    Process.send_after(self(), :sync_with_peers, 100)

    Logger.info("[Replica] Started on #{replica_id} with cluster_size=#{cluster_size}")

    {:ok, state}
  end

  @impl true
  def handle_call({:propose, command}, from, state) do
    available = length(Membership.replicas())
    needed = Quorum.slow_quorum_size(state.cluster_size)

    if available < needed do
      {:reply, {:error, :no_quorum, %{
        cluster_size: state.cluster_size,
        available: available,
        needed: needed
      }}, state}
    else
      {_instance_id, state} = start_proposal(command, from, state)
      {:noreply, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      replica_id: state.replica_id,
      cluster_size: state.cluster_size,
      active_fsms: map_size(state.instances),
      replicas: Membership.replicas() |> Enum.map(&node/1),
      available: length(Membership.replicas()),
      needed_for_quorum: Quorum.slow_quorum_size(state.cluster_size)
    }
    {:reply, info, state}
  end

  # Protocol messages from remote replicas

  @impl true
  def handle_cast({:protocol, %{type: :preaccept} = msg}, state) do
    state = handle_preaccept(msg, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :preaccept_ok} = msg}, state) do
    route_to_fsm(msg.instance_id, {:preaccept_ok, msg.from, msg}, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :accept} = msg}, state) do
    state = handle_accept(msg, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :accept_ok} = msg}, state) do
    route_to_fsm(msg.instance_id, {:accept_ok, msg.from, msg}, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :commit} = msg}, state) do
    state = handle_commit(msg, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :prepare} = msg}, state) do
    state = handle_prepare(msg, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :prepare_ok} = msg}, state) do
    route_to_fsm(msg.instance_id, {:prepare_ok, msg.from, msg}, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :try_preaccept} = msg}, state) do
    state = handle_try_preaccept(msg, state)
    {:noreply, state}
  end

  def handle_cast({:protocol, %{type: :try_preaccept_ok} = msg}, state) do
    route_to_fsm(msg.instance_id, {:try_preaccept_ok, msg.from, msg}, state)
    {:noreply, state}
  end

  # Recovery request from Executor
  def handle_cast({:recover, instance_id}, state) do
    Logger.info("[Replica] Starting recovery for #{inspect(instance_id)}")
    state = start_recovery(instance_id, state)
    {:noreply, state}
  end

  # Sync protocol - request from peer
  def handle_cast({:protocol, %{type: :sync_request, from: from_node}}, state) do
    Logger.debug("[Replica] Sync request from #{from_node}")

    # Gather all committed instances from ETS
    committed = :ets.tab2list(state.table)
                |> Enum.filter(fn {_id, inst} -> inst.status == :committed end)
                |> Enum.map(fn {_id, inst} -> inst end)

    # Send them back
    response = %{
      type: :sync_response,
      instances: committed,
      from: state.replica_id
    }
    send_to_requester(from_node, response)

    {:noreply, state}
  end

  # Sync protocol - response from peer
  def handle_cast({:protocol, %{type: :sync_response, instances: instances, from: from_node}}, state) do
    Logger.debug("[Replica] Sync response from #{from_node} with #{length(instances)} instances")

    # Learn any instances we don't have
    Enum.each(instances, fn instance ->
      case :ets.lookup(state.table, instance.id) do
        [] ->
          # Don't have it - store and notify executor
          :ets.insert(state.table, {instance.id, instance})
          Executor.notify_committed(instance)

        [{_id, existing}] when existing.status != :committed ->
          # Have it but not committed - update and notify
          :ets.insert(state.table, {instance.id, instance})
          Executor.notify_committed(instance)

        _ ->
          # Already have it committed
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_with_peers, state) do
    Logger.debug("[Replica] Requesting sync from peers")

    msg = {:protocol, %{
      type: :sync_request,
      from: state.replica_id
    }}

    for pid <- Membership.remote_replicas() do
      GenServer.cast(pid, msg)
    end

    {:noreply, state}
  end

  def handle_info({:executed, instance_id, result}, state) do
    route_to_fsm(instance_id, {:executed, result}, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    instances = state.instances
                |> Enum.reject(fn {_id, p} -> p == pid end)
                |> Map.new()
    {:noreply, %{state | instances: instances}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Internal Functions

  defp start_proposal(command, from, state) do
    instance_id = {state.replica_id, System.monotonic_time(:nanosecond)}

    # Calculate initial seq and deps
    interfering = Consensus.find_interfering(state.table, command, state.command_module)
    seq = Consensus.initial_seq(interfering)
    deps = Consensus.initial_deps(interfering)

    # Create instance
    instance = %Instance{
      id: instance_id,
      command: command,
      seq: seq,
      deps: deps,
      status: :preaccepted,
      ballot: Ballot.initial(state.replica_id)
    }

    # Store in ETS
    :ets.insert(state.table, {instance_id, instance})

    # Start FSM
    {:ok, pid} = InstanceFSM.start_link(
      instance: instance,
      table: state.table,
      command_module: state.command_module,
      cluster_size: state.cluster_size,
      from: from
    )

    Process.monitor(pid)

    state = %{state | instances: Map.put(state.instances, instance_id, pid)}

    {instance_id, state}
  end

  defp start_recovery(instance_id, state) do
    # Don't recover if we already have an FSM for this
    if Map.has_key?(state.instances, instance_id) do
      Logger.debug("[Replica] Already have FSM for #{inspect(instance_id)}, skipping recovery")
      state
    else
      # Check if already committed in ETS
      instance = case :ets.lookup(state.table, instance_id) do
        [{^instance_id, existing}] when existing.status == :committed ->
          # Already committed locally - just notify executor
          Logger.debug("[Replica] #{inspect(instance_id)} already committed in ETS")
          Executor.notify_committed(existing)
          nil

        [{^instance_id, existing}] ->
          # Exists but not committed - use it for recovery
          existing

        [] ->
          # Create placeholder for recovery
          %Instance{
            id: instance_id,
            command: nil,
            seq: 0,
            deps: MapSet.new(),
            status: :none,
            ballot: Ballot.initial(state.replica_id)
          }
      end

      if instance do
        # Start FSM in recovery mode
        {:ok, pid} = InstanceFSM.start_link(
          instance: instance,
          table: state.table,
          command_module: state.command_module,
          cluster_size: state.cluster_size,
          from: nil,
          start_state: :recovering
        )

        Process.monitor(pid)

        %{state | instances: Map.put(state.instances, instance_id, pid)}
      else
        state
      end
    end
  end

  defp handle_preaccept(msg, state) do
    instance_id = msg.instance_id
    remote_instance = msg.instance
    incoming_ballot = msg.ballot

    case check_ballot(state.table, instance_id, incoming_ballot) do
      :ok ->
        # Calculate our own seq/deps
        interfering = Consensus.find_interfering(state.table, remote_instance.command, state.command_module)
        my_seq = Consensus.initial_seq(interfering)
        my_deps = Consensus.initial_deps(interfering)

        merged_seq = max(remote_instance.seq, my_seq)
        merged_deps = MapSet.union(remote_instance.deps, my_deps)

        # Store the instance
        instance = %{remote_instance |
          seq: merged_seq,
          deps: merged_deps,
          ballot: incoming_ballot
        }
        :ets.insert(state.table, {instance_id, instance})

        # Send response
        response = %{
          type: :preaccept_ok,
          instance_id: instance_id,
          seq: merged_seq,
          deps: merged_deps,
          from: state.replica_id
        }
        send_to_replica(instance_id, response)

      :rejected ->
        :ok
    end

    state
  end

  defp handle_accept(msg, state) do
    instance_id = msg.instance_id
    incoming_ballot = msg.ballot

    case check_ballot(state.table, instance_id, incoming_ballot) do
      :ok ->
        instance = %{msg.instance | status: :accepted, ballot: incoming_ballot}
        :ets.insert(state.table, {instance_id, instance})

        response = %{
          type: :accept_ok,
          instance_id: instance_id,
          from: state.replica_id
        }
        send_to_replica(instance_id, response)

      :rejected ->
        :ok
    end

    state
  end

  defp handle_commit(msg, state) do
    instance_id = msg.instance_id
    instance = %{msg.instance | status: :committed}
    :ets.insert(state.table, {instance_id, instance})

    Executor.notify_committed(instance)

    state
  end

  defp handle_prepare(msg, state) do
    instance_id = msg.instance_id
    incoming_ballot = msg.ballot
    requester = msg.from  # Who wants the PrepareOK

    case check_ballot(state.table, instance_id, incoming_ballot) do
      :ok ->
        instance = case :ets.lookup(state.table, instance_id) do
          [{^instance_id, inst}] ->
            :ets.insert(state.table, {instance_id, %{inst | ballot: incoming_ballot}})
            inst
          [] ->
            nil
        end

        response = %{
          type: :prepare_ok,
          instance_id: instance_id,
          instance: instance,
          from: state.replica_id
        }
        send_to_requester(requester, response)

      :rejected ->
        :ok
    end

    state
  end

  defp handle_try_preaccept(msg, state) do
    instance_id = msg.instance_id
    remote_instance = msg.instance
    incoming_ballot = msg.ballot

    case check_ballot(state.table, instance_id, incoming_ballot) do
      :ok ->
        # Check for conflicts using Core.Conflict
        {replica_id, instance_num} = instance_id

        case Eparl.Core.Conflict.find_preaccept_conflicts(
          state.table,
          remote_instance.command,
          state.command_module,
          replica_id,
          instance_num,
          remote_instance.seq,
          remote_instance.deps
        ) do
          {:ok, :no_conflict} ->
            instance = %{remote_instance | ballot: incoming_ballot, status: :preaccepted}
            :ets.insert(state.table, {instance_id, instance})

            response = %{
              type: :try_preaccept_ok,
              instance_id: instance_id,
              ok: true,
              from: state.replica_id
            }
            send_to_replica(instance_id, response)

          {:conflict, conflict_replica, conflict_instance, conflict_status} ->
            response = %{
              type: :try_preaccept_ok,
              instance_id: instance_id,
              ok: false,
              from: state.replica_id,
              conflict_replica: conflict_replica,
              conflict_instance: conflict_instance,
              conflict_status: conflict_status
            }
            send_to_replica(instance_id, response)
        end

      :rejected ->
        :ok
    end

    state
  end

  defp check_ballot(table, instance_id, incoming_ballot) do
    case :ets.lookup(table, instance_id) do
      [{^instance_id, instance}] ->
        if Ballot.gte?(incoming_ballot, instance.ballot) do
          :ok
        else
          :rejected
        end
      [] ->
        :ok
    end
  end

  defp route_to_fsm(instance_id, message, state) do
    case Map.get(state.instances, instance_id) do
      nil -> :ok
      pid -> GenStateMachine.cast(pid, message)
    end
  end

  defp send_to_replica(instance_id, response) do
    {owner_replica, _} = instance_id

    case find_replica_pid(owner_replica) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:protocol, response})
    end
  end

  defp send_to_requester(requester_node, response) do
    case find_replica_pid(requester_node) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:protocol, response})
    end
  end

  defp find_replica_pid(replica_id) do
    Membership.replicas()
    |> Enum.find(fn pid -> node(pid) == replica_id end)
  end
end
