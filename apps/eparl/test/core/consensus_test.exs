defmodule Eparl.Core.ConsensusTest do
  use ExUnit.Case, async: true

  alias Eparl.Core.Consensus
  alias Eparl.Data.Instance

  # Test command module
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

  describe "find_interfering/3" do
    test "returns empty list when no instances exist", %{table: table} do
      assert Consensus.find_interfering(table, {:put, "a", 1}, TestCmd) == []
    end

    test "finds interfering instances", %{table: table} do
      instance = %Instance{
        id: {:node1, 1},
        command: {:put, "a", 1},
        seq: 1,
        deps: MapSet.new(),
        status: :committed
      }
      :ets.insert(table, {instance.id, instance})

      # Same key - interferes
      result = Consensus.find_interfering(table, {:put, "a", 2}, TestCmd)
      assert length(result) == 1
      assert hd(result).id == {:node1, 1}

      # Different key - no interference
      result = Consensus.find_interfering(table, {:put, "b", 1}, TestCmd)
      assert result == []
    end

    test "finds multiple interfering instances", %{table: table} do
      i1 = %Instance{id: {:node1, 1}, command: {:put, "a", 1}, seq: 1, deps: MapSet.new(), status: :committed}
      i2 = %Instance{id: {:node1, 2}, command: {:put, "a", 2}, seq: 2, deps: MapSet.new(), status: :committed}
      i3 = %Instance{id: {:node2, 1}, command: {:put, "b", 1}, seq: 1, deps: MapSet.new(), status: :committed}

      :ets.insert(table, {i1.id, i1})
      :ets.insert(table, {i2.id, i2})
      :ets.insert(table, {i3.id, i3})

      result = Consensus.find_interfering(table, {:get, "a"}, TestCmd)
      assert length(result) == 2
    end
  end

  describe "initial_seq/1" do
    test "returns 1 when no interfering instances" do
      assert Consensus.initial_seq([]) == 1
    end

    test "returns max seq + 1" do
      instances = [
        %Instance{id: {:a, 1}, command: :noop, seq: 3, deps: MapSet.new()},
        %Instance{id: {:a, 2}, command: :noop, seq: 7, deps: MapSet.new()},
        %Instance{id: {:a, 3}, command: :noop, seq: 2, deps: MapSet.new()}
      ]
      assert Consensus.initial_seq(instances) == 8
    end
  end

  describe "initial_deps/1" do
    test "returns empty MapSet when no interfering instances" do
      assert Consensus.initial_deps([]) == MapSet.new()
    end

    test "returns set of instance ids" do
      instances = [
        %Instance{id: {:node1, 1}, command: :noop, seq: 1, deps: MapSet.new()},
        %Instance{id: {:node2, 5}, command: :noop, seq: 1, deps: MapSet.new()}
      ]
      deps = Consensus.initial_deps(instances)
      assert MapSet.member?(deps, {:node1, 1})
      assert MapSet.member?(deps, {:node2, 5})
      assert MapSet.size(deps) == 2
    end
  end

  describe "fast_path?/1" do
    test "returns true when all responses have same seq and deps" do
      responses = [
        %{seq: 5, deps: MapSet.new([{:a, 1}])},
        %{seq: 5, deps: MapSet.new([{:a, 1}])},
        %{seq: 5, deps: MapSet.new([{:a, 1}])}
      ]
      assert Consensus.fast_path?(responses) == true
    end

    test "returns false when seq differs" do
      responses = [
        %{seq: 5, deps: MapSet.new([{:a, 1}])},
        %{seq: 6, deps: MapSet.new([{:a, 1}])},
        %{seq: 5, deps: MapSet.new([{:a, 1}])}
      ]
      assert Consensus.fast_path?(responses) == false
    end

    test "returns false when deps differ" do
      responses = [
        %{seq: 5, deps: MapSet.new([{:a, 1}])},
        %{seq: 5, deps: MapSet.new([{:a, 1}, {:b, 2}])},
        %{seq: 5, deps: MapSet.new([{:a, 1}])}
      ]
      assert Consensus.fast_path?(responses) == false
    end

    test "returns true for single response" do
      responses = [%{seq: 5, deps: MapSet.new()}]
      assert Consensus.fast_path?(responses) == true
    end
  end

  describe "merge_seq/1" do
    test "returns max seq from responses" do
      responses = [
        %{seq: 3},
        %{seq: 7},
        %{seq: 5}
      ]
      assert Consensus.merge_seq(responses) == 7
    end
  end

  describe "merge_deps/1" do
    test "returns union of all deps" do
      responses = [
        %{deps: MapSet.new([{:a, 1}])},
        %{deps: MapSet.new([{:b, 2}])},
        %{deps: MapSet.new([{:a, 1}, {:c, 3}])}
      ]
      merged = Consensus.merge_deps(responses)
      assert MapSet.size(merged) == 3
      assert MapSet.member?(merged, {:a, 1})
      assert MapSet.member?(merged, {:b, 2})
      assert MapSet.member?(merged, {:c, 3})
    end
  end
end
