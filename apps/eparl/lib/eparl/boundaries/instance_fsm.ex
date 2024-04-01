defmodule Eparl.Boundaries.InstanceFSM do
  @moduledoc """
  GenStateMachine for a single instance going through consensus.

  States:
  - :preaccepted - Initial phase, collecting PreAcceptOK responses
  - :accepted - Slow path, collecting AcceptOK responses
  - :committed - Consensus reached, waiting for execution
  - :recovering - Collecting Prepare responses
  - :try_preaccepting - TryPreAccept optimization during recovery
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias Eparl.Boundaries.{Membership, Executor}
  alias Eparl.Core.{Consensus, Quorum, Recovery}
  alias Eparl.Data.Ballot

  defstruct [
    :instance,
    :table,
    :command_module,
    :from,
    :ballot,
    :cluster_size,
    :leader_responded,
    :possible_quorum,
    responses: []
  ]

  @preaccept_timeout 2000
  @accept_timeout 2000
  @recovery_timeout 5000
  @try_preaccept_timeout 3000

  # Client API

  def start_link(opts) do
    GenStateMachine.start_link(__MODULE__, opts)
  end

  # Callbacks

  @impl true
  def init(opts) do
    instance = Keyword.fetch!(opts, :instance)
    table = Keyword.fetch!(opts, :table)
    command_module = Keyword.fetch!(opts, :command_module)
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    from = Keyword.fetch!(opts, :from)
    start_state = Keyword.get(opts, :start_state, :preaccepted)

    ballot = instance.ballot || Ballot.initial(node())

    data = %__MODULE__{
      instance: %{instance | ballot: ballot},
      table: table,
      command_module: command_module,
      from: from,
      ballot: ballot,
      cluster_size: cluster_size,
      leader_responded: false,
      possible_quorum: MapSet.new()
    }

    case start_state do
      :preaccepted ->
        self_response = %{seq: instance.seq, deps: instance.deps}
        data = %{data | responses: [self_response]}
        {:ok, :preaccepted, data}

      :recovering ->
        Logger.debug("[FSM] Starting in recovery mode for #{inspect(instance.id)}")
        {:ok, :recovering, data}
    end
  end

  #
  # PREACCEPTED STATE
  #

  def preaccepted(:enter, _old_state, data) do
    broadcast_preaccept(data.instance, data.ballot)
    {:keep_state_and_data, [{:state_timeout, @preaccept_timeout, :timeout}]}
  end

  def preaccepted(:cast, {:preaccept_ok, _from_replica, response}, data) do
    responses = [response | data.responses]
    data = %{data | responses: responses}

    cond do
      Quorum.has_fast_quorum?(responses, data.cluster_size) and Consensus.fast_path?(responses) ->
        {:next_state, :committed, data}

      Quorum.has_slow_quorum?(responses, data.cluster_size) ->
        new_seq = Consensus.merge_seq(responses)
        new_deps = Consensus.merge_deps(responses)
        instance = %{data.instance | seq: new_seq, deps: new_deps, status: :accepted}
        :ets.insert(data.table, {instance.id, instance})
        {:next_state, :accepted, %{data | instance: instance, responses: []}}

      true ->
        {:keep_state, data}
    end
  end

  def preaccepted(:state_timeout, :timeout, data) do
    if Quorum.has_slow_quorum?(data.responses, data.cluster_size) do
      new_seq = Consensus.merge_seq(data.responses)
      new_deps = Consensus.merge_deps(data.responses)
      instance = %{data.instance | seq: new_seq, deps: new_deps, status: :accepted}
      :ets.insert(data.table, {instance.id, instance})
      {:next_state, :accepted, %{data | instance: instance, responses: []}}
    else
      {:next_state, :recovering, %{data | responses: []}}
    end
  end

  def preaccepted(:cast, _msg, _data), do: :keep_state_and_data

  #
  # ACCEPTED STATE
  #

  def accepted(:enter, _old_state, data) do
    broadcast_accept(data.instance, data.ballot)
    {:keep_state_and_data, [{:state_timeout, @accept_timeout, :timeout}]}
  end

  def accepted(:cast, {:accept_ok, _from_replica, response}, data) do
    responses = [response | data.responses]
    data = %{data | responses: responses}

    # +1 for self
    total_accepts = length(responses) + 1

    if total_accepts >= Quorum.slow_quorum_size(data.cluster_size) do
      {:next_state, :committed, data}
    else
      {:keep_state, data}
    end
  end

  def accepted(:state_timeout, :timeout, data) do
    {:next_state, :recovering, %{data | responses: []}}
  end

  def accepted(:cast, _msg, _data), do: :keep_state_and_data

  #
  # COMMITTED STATE
  #

  def committed(:enter, _old_state, data) do
    instance = %{data.instance | status: :committed}
    :ets.insert(data.table, {instance.id, instance})

    Logger.debug("[FSM] Instance #{inspect(instance.id)} committed")

    broadcast_commit(instance)
    Executor.notify_committed(instance)

    {:keep_state, %{data | instance: instance}}
  end

  def committed(:cast, {:executed, result}, data) do
    Logger.debug("[FSM] Instance #{inspect(data.instance.id)} executed with result: #{inspect(result)}")
    if data.from, do: GenStateMachine.reply(data.from, {:ok, result})
    {:stop, :normal, data}
  end

  def committed(:cast, _msg, _data), do: :keep_state_and_data

  #
  # RECOVERING STATE
  #

  def recovering(:enter, _old_state, data) do
    new_ballot = Ballot.higher_than(data.ballot, node())

    instance = %{data.instance | ballot: new_ballot}
    :ets.insert(data.table, {instance.id, instance})

    Logger.debug("[FSM] Recovery: broadcasting Prepare for #{inspect(instance.id)} with ballot #{inspect(new_ballot)}")

    broadcast_prepare(instance.id, new_ballot)

    new_data = %{data |
      ballot: new_ballot,
      instance: instance,
      responses: [],
      leader_responded: false
    }
    {:keep_state, new_data, [{:state_timeout, @recovery_timeout, :timeout}]}
  end

  def recovering(:cast, {:prepare_ok, from_replica, response}, data) do
    responses = [response | data.responses]

    # Check if original leader responded
    {leader_replica, _} = data.instance.id
    leader_responded = data.leader_responded or (from_replica == leader_replica)

    data = %{data | responses: responses, leader_responded: leader_responded}

    if Quorum.has_slow_quorum?(responses, data.cluster_size) do
      Logger.debug("[FSM] Recovery: got quorum for #{inspect(data.instance.id)}")

      case Recovery.analyze(responses, data.cluster_size, leader_responded) do
        {:commit, instance} ->
          Logger.debug("[FSM] Recovery: learned committed value for #{inspect(instance.id)}")
          instance = %{instance | ballot: data.ballot}
          {:next_state, :committed, %{data | instance: instance}}

        {:accept, instance} ->
          instance = %{instance | ballot: data.ballot, status: :accepted}
          :ets.insert(data.table, {instance.id, instance})
          {:next_state, :accepted, %{data | instance: instance, responses: []}}

        {:try_preaccept, instance} ->
          instance = %{instance | ballot: data.ballot}
          # Initialize possible quorum with all replicas
          all_replicas =
            Membership.replicas()
            |> Enum.map(&node/1)
            |> MapSet.new()

          {:next_state, :try_preaccepting, %{data |
            instance: instance,
            responses: [],
            possible_quorum: all_replicas
          }}

        {:restart_phase1, instance} ->
          # Restart preaccept with recovered values
          instance = %{instance | ballot: data.ballot, status: :preaccepted}
          :ets.insert(data.table, {instance.id, instance})
          self_response = %{seq: instance.seq, deps: instance.deps}
          {:next_state, :preaccepted, %{data | instance: instance, responses: [self_response]}}

        :not_found ->
          Logger.warning("[FSM] Recovery: instance #{inspect(data.instance.id)} not found on any replica")
          if data.from, do: GenStateMachine.reply(data.from, {:error, :not_found})
          {:stop, :normal, data}
      end
    else
      {:keep_state, data}
    end
  end

  def recovering(:state_timeout, :timeout, data) do
    Logger.warning("[FSM] Recovery timeout for #{inspect(data.instance.id)}")
    if data.from, do: GenStateMachine.reply(data.from, {:error, :recovery_timeout})
    {:stop, :normal, data}
  end

  def recovering(:cast, _msg, _data), do: :keep_state_and_data

  #
  # TRY_PREACCEPTING STATE
  #

  def try_preaccepting(:enter, _old_state, data) do
    broadcast_try_preaccept(data.instance, data.ballot)
    {:keep_state_and_data, [{:state_timeout, @try_preaccept_timeout, :timeout}]}
  end

  def try_preaccepting(:cast, {:try_preaccept_ok, _from_replica, response}, data) do
    responses = [response | data.responses]
    data = %{data | responses: responses}

    case Recovery.analyze_try_preaccept(responses, data.cluster_size, data.possible_quorum) do
      {:accept, possible_quorum} ->
        instance = %{data.instance | status: :accepted}
        :ets.insert(data.table, {instance.id, instance})
        {:next_state, :accepted, %{data |
          instance: instance,
          responses: [],
          possible_quorum: possible_quorum
        }}

      {:restart, _possible_quorum} ->
        # Restart from preaccept
        instance = %{data.instance | status: :preaccepted}
        :ets.insert(data.table, {instance.id, instance})
        self_response = %{seq: instance.seq, deps: instance.deps}
        {:next_state, :preaccepted, %{data | instance: instance, responses: [self_response]}}

      {:continue, possible_quorum} ->
        {:keep_state, %{data | possible_quorum: possible_quorum}}
    end
  end

  def try_preaccepting(:state_timeout, :timeout, data) do
    # Timeout - restart from preaccept
    instance = %{data.instance | status: :preaccepted}
    :ets.insert(data.table, {instance.id, instance})
    self_response = %{seq: instance.seq, deps: instance.deps}
    {:next_state, :preaccepted, %{data | instance: instance, responses: [self_response]}}
  end

  def try_preaccepting(:cast, _msg, _data), do: :keep_state_and_data

  #
  # PROTOCOL MESSAGE BROADCASTING
  #

  defp broadcast_preaccept(instance, ballot) do
    msg = {:protocol, %{
      type: :preaccept,
      instance_id: instance.id,
      instance: instance,
      ballot: ballot
    }}
    for pid <- Membership.remote_replicas(), do: GenServer.cast(pid, msg)
  end

  defp broadcast_accept(instance, ballot) do
    msg = {:protocol, %{
      type: :accept,
      instance_id: instance.id,
      instance: instance,
      ballot: ballot
    }}
    for pid <- Membership.remote_replicas(), do: GenServer.cast(pid, msg)
  end

  defp broadcast_commit(instance) do
    msg = {:protocol, %{
      type: :commit,
      instance_id: instance.id,
      instance: instance
    }}
    for pid <- Membership.remote_replicas(), do: GenServer.cast(pid, msg)
  end

  defp broadcast_prepare(instance_id, ballot) do
    msg = {:protocol, %{
      type: :prepare,
      instance_id: instance_id,
      ballot: ballot,
      from: node()
    }}
    for pid <- Membership.remote_replicas(), do: GenServer.cast(pid, msg)
  end

  defp broadcast_try_preaccept(instance, ballot) do
    msg = {:protocol, %{
      type: :try_preaccept,
      instance_id: instance.id,
      instance: instance,
      ballot: ballot
    }}
    for pid <- Membership.remote_replicas(), do: GenServer.cast(pid, msg)
  end
end
