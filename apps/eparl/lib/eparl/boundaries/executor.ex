defmodule Eparl.Boundaries.Executor do
  @moduledoc """
  Executes committed instances in dependency order.

  An instance can be executed when all its dependencies have been executed.
  Uses Tarjan's SCC to handle dependency cycles.

  When a dependency is missing (not known locally), the Executor triggers
  recovery for that instance after a grace period. Recovery learns the
  committed value from other replicas.
  """

  use GenServer
  require Logger

  alias Eparl.Core.Ordering

  @grace_period_ms 2_000  # 2 seconds before triggering recovery

  defstruct [
    :command_module,
    :app_state,
    committed: %{},              # %{instance_id => instance} - waiting to execute
    executed: MapSet.new(),      # instance_ids that have been executed
    missing_deps: %{},           # %{dep_id => first_seen_timestamp}
    recovery_in_progress: MapSet.new(),  # dep_ids we're already recovering
    blocked_timer: nil           # timer ref for checking blocked deps
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def notify_committed(instance) do
    GenServer.cast(__MODULE__, {:committed, instance})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    command_module = Keyword.fetch!(opts, :command_module)
    initial_state = Keyword.get(opts, :initial_state, %{})

    state = %__MODULE__{
      command_module: command_module,
      app_state: initial_state
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:committed, instance}, state) do
    Logger.debug("[Executor] Instance #{inspect(instance.id)} committed")

    # Add to committed map
    new_committed = Map.put(state.committed, instance.id, instance)
    state = %{state | committed: new_committed}

    # Clear from recovery tracking if we were recovering it
    state = %{state |
      recovery_in_progress: MapSet.delete(state.recovery_in_progress, instance.id),
      missing_deps: Map.delete(state.missing_deps, instance.id)
    }

    # Try to execute what we can
    state = execute_ready(state)

    # Schedule check for blocked deps if needed
    state = maybe_schedule_blocked_check(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_blocked, state) do
    state = %{state | blocked_timer: nil}
    state = check_and_recover_blocked(state)
    state = maybe_schedule_blocked_check(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Find and execute instances whose dependencies are satisfied
  defp execute_ready(state) do
    ready =
      state.committed
      |> Map.values()
      |> Enum.filter(fn instance ->
        MapSet.subset?(instance.deps, state.executed)
      end)

    case ready do
      [] ->
        state

      instances ->
        order = Ordering.execution_order(instances)
        state = execute_in_order(order, state)
        execute_ready(state)
    end
  end

  defp execute_in_order([], state), do: state
  defp execute_in_order([id | rest], state) do
    case Map.fetch(state.committed, id) do
      {:ok, instance} ->
        Logger.debug("[Executor] Executing #{inspect(id)}")

        {result, new_app_state} = state.command_module.execute(instance.command, state.app_state)

        new_state = %{state |
          app_state: new_app_state,
          committed: Map.delete(state.committed, id),
          executed: MapSet.put(state.executed, id)
        }

        notify_fsm(id, result)

        execute_in_order(rest, new_state)

      :error ->
        execute_in_order(rest, state)
    end
  end

  # Check for blocked dependencies and trigger recovery if grace period exceeded
  defp check_and_recover_blocked(state) do
    now = System.monotonic_time(:millisecond)

    # Find all missing deps
    all_missing = find_missing_deps(state)

    if all_missing != [] do
      Logger.debug("[Executor] Missing deps: #{inspect(all_missing)}")
    end

    # Update tracking and find what needs recovery
    {state, to_recover} =
      Enum.reduce(all_missing, {state, []}, fn dep_id, {st, recover_list} ->
        cond do
          # Already recovering
          MapSet.member?(st.recovery_in_progress, dep_id) ->
            {st, recover_list}

          # Already tracking - check grace period
          Map.has_key?(st.missing_deps, dep_id) ->
            first_seen = Map.get(st.missing_deps, dep_id)
            if now - first_seen >= @grace_period_ms do
              {st, [dep_id | recover_list]}
            else
              {st, recover_list}
            end

          # New - start tracking
          true ->
            new_missing = Map.put(st.missing_deps, dep_id, now)
            {%{st | missing_deps: new_missing}, recover_list}
        end
      end)

    # Clean up deps that are no longer missing
    state = %{state | missing_deps: Map.take(state.missing_deps, all_missing)}

    # Trigger recovery for deps that exceeded grace period
    Enum.reduce(to_recover, state, fn dep_id, st ->
      Logger.info("[Executor] Triggering recovery for missing dep #{inspect(dep_id)}")
      trigger_recovery(dep_id)
      %{st |
        recovery_in_progress: MapSet.put(st.recovery_in_progress, dep_id),
        missing_deps: Map.delete(st.missing_deps, dep_id)
      }
    end)
  end

  # Find deps that are not executed AND not committed locally
  defp find_missing_deps(state) do
    state.committed
    |> Map.values()
    |> Enum.flat_map(fn instance ->
      # Deps that aren't executed
      not_executed = MapSet.difference(instance.deps, state.executed)

      # And also not committed locally
      not_executed
      |> MapSet.to_list()
      |> Enum.reject(fn dep_id -> Map.has_key?(state.committed, dep_id) end)
    end)
    |> Enum.uniq()
  end

  defp maybe_schedule_blocked_check(state) do
    has_missing = map_size(state.missing_deps) > 0 or
                  not Enum.empty?(find_missing_deps(state))

    cond do
      state.blocked_timer != nil ->
        state

      has_missing ->
        ref = Process.send_after(self(), :check_blocked, @grace_period_ms)
        %{state | blocked_timer: ref}

      true ->
        state
    end
  end

  defp trigger_recovery(instance_id) do
    GenServer.cast(Eparl.Boundaries.Replica, {:recover, instance_id})
  end

  defp notify_fsm(instance_id, result) do
    send(Eparl.Boundaries.Replica, {:executed, instance_id, result})
  end
end
