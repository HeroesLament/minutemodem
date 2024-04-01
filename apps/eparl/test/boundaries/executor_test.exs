defmodule Eparl.Boundaries.ExecutorTest do
  use ExUnit.Case

  alias Eparl.Boundaries.Executor
  alias Eparl.Data.Instance

  defmodule TestCmd do
    def interferes?(_, _), do: false
    def execute({:put, _k, v}, state), do: {:ok, Map.put(state, :value, (state[:value] || 0) + v)}
    def execute({:get, _k}, state), do: {state[:value], state}
  end

  setup do
    # Register a dummy process as Replica to receive :executed messages
    # This prevents the "invalid destination" error
    dummy = spawn(fn ->
      receive_loop()
    end)
    Process.register(dummy, Eparl.Boundaries.Replica)

    # Start executor for each test
    {:ok, executor} = start_supervised({Executor, command_module: TestCmd, initial_state: %{}})

    on_exit(fn ->
      if Process.whereis(Eparl.Boundaries.Replica) == dummy do
        Process.unregister(Eparl.Boundaries.Replica)
      end
      Process.exit(dummy, :kill)
    end)

    {:ok, executor: executor, dummy_replica: dummy}
  end

  defp receive_loop do
    receive do
      _ -> receive_loop()
    end
  end

  describe "notify_committed/1" do
    test "executes instance with no dependencies" do
      instance = %Instance{
        id: {:a, 1},
        command: {:put, "key", 100},
        seq: 1,
        deps: MapSet.new(),
        status: :committed
      }

      Executor.notify_committed(instance)

      # Give it time to execute
      Process.sleep(100)

      state = :sys.get_state(Executor)
      assert MapSet.member?(state.executed, {:a, 1})
      assert state.app_state[:value] == 100
    end

    test "waits for dependencies before executing" do
      # Instance 2 depends on instance 1
      i2 = %Instance{
        id: {:a, 2},
        command: {:get, "key"},
        seq: 2,
        deps: MapSet.new([{:a, 1}]),
        status: :committed
      }

      Executor.notify_committed(i2)
      Process.sleep(100)

      # Should not be executed yet - waiting for dependency
      state = :sys.get_state(Executor)
      assert {:a, 2} in Map.keys(state.committed)
      refute MapSet.member?(state.executed, {:a, 2})

      # Now commit the dependency
      i1 = %Instance{
        id: {:a, 1},
        command: {:put, "key", 50},
        seq: 1,
        deps: MapSet.new(),
        status: :committed
      }

      Executor.notify_committed(i1)
      Process.sleep(100)

      # Both should be executed now
      state = :sys.get_state(Executor)
      assert MapSet.member?(state.executed, {:a, 1})
      assert MapSet.member?(state.executed, {:a, 2})
    end

    test "executes multiple independent instances" do
      i1 = %Instance{id: {:a, 1}, command: {:put, "a", 10}, seq: 1, deps: MapSet.new(), status: :committed}
      i2 = %Instance{id: {:a, 2}, command: {:put, "b", 20}, seq: 2, deps: MapSet.new(), status: :committed}
      i3 = %Instance{id: {:a, 3}, command: {:put, "c", 30}, seq: 3, deps: MapSet.new(), status: :committed}

      Executor.notify_committed(i3)
      Executor.notify_committed(i1)
      Executor.notify_committed(i2)

      Process.sleep(100)

      state = :sys.get_state(Executor)
      assert MapSet.member?(state.executed, {:a, 1})
      assert MapSet.member?(state.executed, {:a, 2})
      assert MapSet.member?(state.executed, {:a, 3})
      # All values added: 10 + 20 + 30 = 60
      assert state.app_state[:value] == 60
    end

    test "maintains app state across executions" do
      i1 = %Instance{
        id: {:a, 1},
        command: {:put, "x", 100},
        seq: 1,
        deps: MapSet.new(),
        status: :committed
      }
      i2 = %Instance{
        id: {:a, 2},
        command: {:put, "y", 200},
        seq: 2,
        deps: MapSet.new([{:a, 1}]),
        status: :committed
      }

      Executor.notify_committed(i1)
      Executor.notify_committed(i2)
      Process.sleep(100)

      state = :sys.get_state(Executor)
      # Both executed, state accumulated
      assert state.app_state[:value] == 300
    end
  end

  describe "missing dependency tracking" do
    test "tracks missing dependencies" do
      # Instance depends on something we don't have
      instance = %Instance{
        id: {:a, 2},
        command: {:get, "key"},
        seq: 2,
        deps: MapSet.new([{:b, 99}]),  # Unknown dependency
        status: :committed
      }

      Executor.notify_committed(instance)
      Process.sleep(100)

      state = :sys.get_state(Executor)

      # Should still be in committed (not executed) because dep is missing
      assert {:a, 2} in Map.keys(state.committed)
      refute MapSet.member?(state.executed, {:a, 2})
    end
  end
end
