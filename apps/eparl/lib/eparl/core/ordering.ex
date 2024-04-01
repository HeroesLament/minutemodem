# core/ordering.ex
defmodule Eparl.Core.Ordering do
  @moduledoc """
  Dependency graph and execution ordering using Tarjan's SCC algorithm.

  ePaxos instances form a dependency graph. To execute, we:
  1. Build the graph from deps
  2. Find strongly connected components (cycles)
  3. Topologically sort the SCCs
  4. Within each SCC, sort by (seq, replica_id, instance_num)
  """

  @doc """
  Build adjacency list from instances.
  Returns %{instance_id => [dep_ids]}
  """
  def build_graph(instances) do
    Map.new(instances, fn instance ->
      {instance.id, MapSet.to_list(instance.deps)}
    end)
  end

  @doc """
  Tarjan's algorithm for strongly connected components.
  Returns list of SCCs in reverse topological order.
  """
  def strongly_connected_components(graph) do
    state = %{
      index: 0,
      stack: [],
      indices: %{},
      lowlinks: %{},
      on_stack: MapSet.new(),
      sccs: []
    }

    nodes = Map.keys(graph)

    final_state = Enum.reduce(nodes, state, fn node, acc ->
      if Map.has_key?(acc.indices, node) do
        acc
      else
        strongconnect(node, graph, acc)
      end
    end)

    final_state.sccs
  end

  defp strongconnect(v, graph, state) do
    state = %{state |
      indices: Map.put(state.indices, v, state.index),
      lowlinks: Map.put(state.lowlinks, v, state.index),
      index: state.index + 1,
      stack: [v | state.stack],
      on_stack: MapSet.put(state.on_stack, v)
    }

    neighbors = Map.get(graph, v, [])

    state = Enum.reduce(neighbors, state, fn w, acc ->
      cond do
        not Map.has_key?(acc.indices, w) ->
          # Only recurse if w is in our graph
          if Map.has_key?(graph, w) do
            acc = strongconnect(w, graph, acc)
            lowlink_v = Map.get(acc.lowlinks, v)
            lowlink_w = Map.get(acc.lowlinks, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, lowlink_w))}
          else
            # Dependency not in our graph - skip it
            acc
          end

        MapSet.member?(acc.on_stack, w) ->
          lowlink_v = Map.get(acc.lowlinks, v)
          index_w = Map.get(acc.indices, w)
          %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, index_w))}

        true ->
          acc
      end
    end)

    if Map.get(state.lowlinks, v) == Map.get(state.indices, v) do
      {scc, new_stack} = pop_scc(state.stack, v, [])
      %{state |
        stack: new_stack,
        on_stack: Enum.reduce(scc, state.on_stack, &MapSet.delete(&2, &1)),
        sccs: [scc | state.sccs]
      }
    else
      state
    end
  end

  defp pop_scc([v | rest], v, acc), do: {[v | acc], rest}
  defp pop_scc([w | rest], v, acc), do: pop_scc(rest, v, [w | acc])

  @doc """
  Sort instances within an SCC by (seq, replica_id, instance_num).
  """
  def sort_within_scc(scc, instances_map) do
    Enum.sort_by(scc, fn id ->
      instance = Map.fetch!(instances_map, id)
      {replica_id, instance_num} = id
      {instance.seq, replica_id, instance_num}
    end)
  end

  @doc """
  Get full execution order for a set of instances.
  Returns flat list of instance_ids in execution order.
  Only returns ids that are in the provided instances list.
  """
  def execution_order(instances) do
    instances_map = Map.new(instances, &{&1.id, &1})
    graph = build_graph(instances)
    sccs = strongly_connected_components(graph)

    sccs
    |> Enum.reverse()
    |> Enum.flat_map(fn scc ->
      # Filter to only instances we have
      known_scc = Enum.filter(scc, &Map.has_key?(instances_map, &1))
      sort_within_scc(known_scc, instances_map)
    end)
  end
end
