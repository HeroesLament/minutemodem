defmodule Eparl.Core.ConflictTest do
  use ExUnit.Case, async: true

  alias Eparl.Core.Conflict
  alias Eparl.Data.Instance

  defmodule TestCmd do
    def interferes?({:put, k1, _}, {:put, k2, _}), do: k1 == k2
    def interferes?({:put, k1, _}, {:get, k2}), do: k1 == k2
    def interferes?({:get, k1}, {:put, k2, _}), do: k1 == k2
    def interferes?(_, _), do: false
  end

  setup do
    table = :ets.new(:test_instances, [:set, :public])
    {:ok, table: table}
  end

  describe "find_preaccept_conflicts/7" do
    test "returns :no_conflict when no instances exist", %{table: table} do
      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 1},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert result == {:ok, :no_conflict}
    end

    test "returns :no_conflict for non-interfering instances", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "b", 1},  # Different key
        seq: 10,
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 1},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert result == {:ok, :no_conflict}
    end

    test "returns :no_conflict when interfering instance is in deps", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},  # Same key - interferes
        seq: 10,
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      # Instance is already in our deps - no conflict
      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new([{:node2, 1}])
      )
      assert result == {:ok, :no_conflict}
    end

    test "returns :no_conflict when interfering instance has lower seq", %{table: table} do
      # Conflict only happens when inst.seq >= our seq
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},
        seq: 3,  # Lower than our seq of 5
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,  # Our seq is 5, instance seq is 3
        MapSet.new()
      )
      # No conflict because inst.seq (3) < our seq (5)
      assert result == {:ok, :no_conflict}
    end

    test "returns conflict when interfering instance has equal seq and not in deps", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},
        seq: 5,  # Equal to our seq
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()  # Not in our deps
      )
      assert {:conflict, :node2, 1, :preaccepted} = result
    end

    test "returns conflict when interfering instance has higher seq", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},
        seq: 10,  # Higher than our seq of 5
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert {:conflict, :node2, 1, :preaccepted} = result
    end

    test "returns conflict for accepted instance", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},
        seq: 5,  # Equal to our seq
        deps: MapSet.new(),
        status: :accepted
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert {:conflict, :node2, 1, :accepted} = result
    end

    test "returns conflict for committed instance", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: {:put, "a", 1},
        seq: 5,  # Equal to our seq
        deps: MapSet.new(),
        status: :committed
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert {:conflict, :node2, 1, :committed} = result
    end

    test "skips self instance", %{table: table} do
      # Store an instance with the same replica/instance we're checking
      instance = %Instance{
        id: {:node1, 1},
        command: {:put, "a", 1},
        seq: 5,
        deps: MapSet.new(),
        status: :preaccepted
      }
      :ets.insert(table, {instance.id, instance})

      # Should not conflict with itself
      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,  # Same replica
        1,       # Same instance num
        5,
        MapSet.new()
      )
      assert result == {:ok, :no_conflict}
    end

    test "skips instances with nil command", %{table: table} do
      instance = %Instance{
        id: {:node2, 1},
        command: nil,  # No command yet (placeholder)
        seq: 5,
        deps: MapSet.new(),
        status: :none
      }
      :ets.insert(table, {instance.id, instance})

      result = Conflict.find_preaccept_conflicts(
        table,
        {:put, "a", 2},
        TestCmd,
        :node1,
        1,
        5,
        MapSet.new()
      )
      assert result == {:ok, :no_conflict}
    end
  end
end
