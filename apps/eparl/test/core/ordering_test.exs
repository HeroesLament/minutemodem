defmodule Eparl.Core.OrderingTest do
  use ExUnit.Case, async: true

  alias Eparl.Core.Ordering
  alias Eparl.Data.Instance

  describe "execution_order/1" do
    test "returns empty list for empty input" do
      assert Ordering.execution_order([]) == []
    end

    test "single instance returns its id" do
      instance = %Instance{id: {:a, 1}, command: :noop, seq: 1, deps: MapSet.new()}
      assert Ordering.execution_order([instance]) == [{:a, 1}]
    end

    test "independent instances sorted by seq, then replica, then instance_num" do
      i1 = %Instance{id: {:a, 1}, command: :noop, seq: 5, deps: MapSet.new()}
      i2 = %Instance{id: {:a, 2}, command: :noop, seq: 3, deps: MapSet.new()}
      i3 = %Instance{id: {:a, 3}, command: :noop, seq: 7, deps: MapSet.new()}

      order = Ordering.execution_order([i1, i2, i3])

      # Each is its own SCC, SCCs returned in reverse topo order
      # Within SCC, sorted by (seq, replica, instance_num)
      # Since no deps, each forms SCC, order determined by Tarjan traversal
      assert length(order) == 3
      assert {:a, 1} in order
      assert {:a, 2} in order
      assert {:a, 3} in order
    end

    test "breaks ties with replica_id then instance_num" do
      i1 = %Instance{id: {:b, 5}, command: :noop, seq: 1, deps: MapSet.new()}
      i2 = %Instance{id: {:a, 3}, command: :noop, seq: 1, deps: MapSet.new()}
      i3 = %Instance{id: {:a, 7}, command: :noop, seq: 1, deps: MapSet.new()}

      order = Ordering.execution_order([i1, i2, i3])

      # All same seq, each is own SCC
      assert length(order) == 3
      assert {:a, 3} in order
      assert {:a, 7} in order
      assert {:b, 5} in order
    end

    test "handles dependencies - dependent comes after dependency" do
      # i2 depends on i1, i3 depends on i2
      i1 = %Instance{id: {:a, 1}, command: :noop, seq: 1, deps: MapSet.new()}
      i2 = %Instance{id: {:a, 2}, command: :noop, seq: 2, deps: MapSet.new([{:a, 1}])}
      i3 = %Instance{id: {:a, 3}, command: :noop, seq: 3, deps: MapSet.new([{:a, 2}])}

      order = Ordering.execution_order([i3, i1, i2])

      # i1 must come before i2, i2 must come before i3
      i1_pos = Enum.find_index(order, &(&1 == {:a, 1}))
      i2_pos = Enum.find_index(order, &(&1 == {:a, 2}))
      i3_pos = Enum.find_index(order, &(&1 == {:a, 3}))

      assert i1_pos < i2_pos
      assert i2_pos < i3_pos
    end

    test "handles dependency cycles (SCC)" do
      # i1 and i2 depend on each other - forms SCC
      i1 = %Instance{id: {:a, 1}, command: :noop, seq: 1, deps: MapSet.new([{:a, 2}])}
      i2 = %Instance{id: {:a, 2}, command: :noop, seq: 2, deps: MapSet.new([{:a, 1}])}

      order = Ordering.execution_order([i1, i2])

      # Both should be in the result
      assert length(order) == 2
      assert {:a, 1} in order
      assert {:a, 2} in order

      # Within SCC, sorted by (seq, replica, instance_num)
      # i1 has seq=1, i2 has seq=2, so i1 comes first
      assert order == [{:a, 1}, {:a, 2}]
    end

    test "handles complex SCC with external deps" do
      # SCC: i1 <-> i2, with i3 depending on both
      i1 = %Instance{id: {:a, 1}, command: :noop, seq: 1, deps: MapSet.new([{:a, 2}])}
      i2 = %Instance{id: {:a, 2}, command: :noop, seq: 1, deps: MapSet.new([{:a, 1}])}
      i3 = %Instance{id: {:a, 3}, command: :noop, seq: 2, deps: MapSet.new([{:a, 1}, {:a, 2}])}

      order = Ordering.execution_order([i3, i1, i2])

      # i3 depends on the SCC, so SCC must come first
      i3_pos = Enum.find_index(order, &(&1 == {:a, 3}))
      i1_pos = Enum.find_index(order, &(&1 == {:a, 1}))
      i2_pos = Enum.find_index(order, &(&1 == {:a, 2}))

      assert i1_pos < i3_pos
      assert i2_pos < i3_pos
    end
  end

  describe "determinism" do
    test "same input always produces same output" do
      instances = [
        %Instance{id: {:c, 1}, command: :noop, seq: 5, deps: MapSet.new([{:a, 1}])},
        %Instance{id: {:a, 1}, command: :noop, seq: 3, deps: MapSet.new()},
        %Instance{id: {:b, 2}, command: :noop, seq: 5, deps: MapSet.new([{:a, 1}])}
      ]

      # Run multiple times, should be identical
      results = for _ <- 1..10, do: Ordering.execution_order(instances)
      assert Enum.uniq(results) |> length() == 1
    end
  end

  describe "build_graph/1" do
    test "builds adjacency list from instances" do
      i1 = %Instance{id: {:a, 1}, command: :noop, seq: 1, deps: MapSet.new()}
      i2 = %Instance{id: {:a, 2}, command: :noop, seq: 2, deps: MapSet.new([{:a, 1}])}

      graph = Ordering.build_graph([i1, i2])

      assert graph[{:a, 1}] == []
      assert graph[{:a, 2}] == [{:a, 1}]
    end
  end

  describe "strongly_connected_components/1" do
    test "finds trivial SCCs (no cycles)" do
      graph = %{
        {:a, 1} => [],
        {:a, 2} => [{:a, 1}]
      }

      sccs = Ordering.strongly_connected_components(graph)

      # Each node is its own SCC
      assert length(sccs) == 2
    end

    test "finds cycle SCC" do
      graph = %{
        {:a, 1} => [{:a, 2}],
        {:a, 2} => [{:a, 1}]
      }

      sccs = Ordering.strongly_connected_components(graph)

      # One SCC containing both
      assert length(sccs) == 1
      assert Enum.sort(hd(sccs)) == [{:a, 1}, {:a, 2}]
    end
  end
end
