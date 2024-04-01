# lib/eparl/core/conflict.ex
defmodule Eparl.Core.Conflict do
  @moduledoc """
  Conflict detection for TryPreAccept recovery optimization.

  Finds instances that conflict with a proposed command and would
  prevent it from being pre-accepted.
  """

  @doc """
  Find conflicts that would prevent pre-accepting this command with given seq/deps.

  Returns:
  - `{:ok, :no_conflict}` - Safe to pre-accept
  - `{:conflict, replica_id, instance_num, status}` - Found a conflicting instance
  """
  def find_preaccept_conflicts(table, command, command_module, replica_id, instance_num, seq, deps) do
    instances = :ets.tab2list(table)
    find_conflict(instances, command, command_module, replica_id, instance_num, seq, deps)
  end

  defp find_conflict([], _command, _module, _replica, _instance, _seq, _deps) do
    {:ok, :no_conflict}
  end

  defp find_conflict([{id, inst} | rest], command, module, replica_id, instance_num, seq, deps) do
    {inst_replica, inst_num} = id

    cond do
      # Skip self
      inst_replica == replica_id and inst_num == instance_num ->
        find_conflict(rest, command, module, replica_id, instance_num, seq, deps)

      # Skip if no command
      inst.command == nil ->
        find_conflict(rest, command, module, replica_id, instance_num, seq, deps)

      # Skip if this instance depends on us (no conflict)
      instance_in_deps?(inst.deps, replica_id, instance_num) ->
        find_conflict(rest, command, module, replica_id, instance_num, seq, deps)

      # Check for actual conflict
      module.interferes?(command, inst.command) ->
        inst_in_our_deps = MapSet.member?(deps, id)

        if not inst_in_our_deps and inst.seq >= seq do
          {:conflict, inst_replica, inst_num, inst.status}
        else
          find_conflict(rest, command, module, replica_id, instance_num, seq, deps)
        end

      true ->
        find_conflict(rest, command, module, replica_id, instance_num, seq, deps)
    end
  end

  defp instance_in_deps?(deps, replica_id, instance_num) do
    MapSet.member?(deps, {replica_id, instance_num})
  end
end
