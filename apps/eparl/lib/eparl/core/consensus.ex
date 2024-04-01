# core/consensus.ex
defmodule Eparl.Core.Consensus do
  @moduledoc """
  Core ePaxos consensus logic.

  Pure functions for calculating sequences, dependencies,
  and determining fast vs slow path.
  """

  @doc """
  Find all instances in the table that interfere with the given command.
  """
  def find_interfering(table, command, command_module) do
    :ets.tab2list(table)
    |> Enum.filter(fn {_id, instance} ->
      command_module.interferes?(command, instance.command)
    end)
    |> Enum.map(fn {_id, instance} -> instance end)
  end

  @doc """
  Calculate initial seq for a new instance based on interfering instances.
  """
  def initial_seq(interfering) do
    case interfering do
      [] -> 1
      instances -> Enum.max_by(instances, & &1.seq).seq + 1
    end
  end

  @doc """
  Calculate initial deps for a new instance.
  """
  def initial_deps(interfering) do
    MapSet.new(interfering, & &1.id)
  end

  @doc """
  Merge seq from PreAccept responses - take the max.
  """
  def merge_seq(responses) do
    responses
    |> Enum.map(& &1.seq)
    |> Enum.max()
  end

  @doc """
  Merge deps from PreAccept responses - union all.
  """
  def merge_deps(responses) do
    responses
    |> Enum.map(& &1.deps)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  @doc """
  Check if all responses agree on seq and deps (fast path condition).
  """
  def fast_path?(responses) do
    case responses do
      [] -> false
      [first | rest] ->
        Enum.all?(rest, fn r ->
          r.seq == first.seq and MapSet.equal?(r.deps, first.deps)
        end)
    end
  end
end
