# lib/eparl/core/recovery.ex
defmodule Eparl.Core.Recovery do
  @moduledoc """
  Recovery analysis logic for ePaxos.

  When a replica recovers an instance, it collects PrepareOK responses
  and must decide how to proceed based on what other replicas know.
  """

  alias Eparl.Core.Quorum

  @doc """
  Analyze PrepareOK responses and decide how to proceed.

  Returns:
  - `{:commit, instance}` - Instance was already committed
  - `{:accept, instance}` - Run Accept phase with this seq/deps
  - `{:try_preaccept, instance}` - Try to pre-accept (optimization)
  - `{:restart_phase1, instance}` - Restart from scratch
  - `:not_found` - Instance never existed
  """
  def analyze(responses, cluster_size, leader_responded \\ false) do
    {with_data, _without_data} = Enum.split_with(responses, fn r -> r.instance != nil end)

    by_status = Enum.group_by(with_data, fn r -> r.instance.status end)

    committed = Map.get(by_status, :committed, [])
    accepted = Map.get(by_status, :accepted, [])
    preaccepted = Map.get(by_status, :preaccepted, [])

    preaccept_count = length(preaccepted)
    half_quorum = div(Quorum.slow_quorum_size(cluster_size) + 1, 2)

    cond do
      # If ANY replica has committed, learn it
      length(committed) > 0 ->
        {:commit, hd(committed).instance}

      # If ANY replica has accepted, use that
      length(accepted) > 0 ->
        best =
          Enum.max_by(accepted, fn r ->
            {r.instance.ballot.epoch, r.instance.ballot.counter, r.instance.ballot.replica_id}
          end)

        {:accept, best.instance}

      # Fast path agreement among preaccepted
      preaccept_count > 0 and fast_path_agreement?(preaccepted, cluster_size) ->
        {:accept, hd(preaccepted).instance}

      # Enough preaccepted to try accept (leader didn't respond, but we have majority)
      preaccept_count >= Quorum.slow_quorum_size(cluster_size) and not leader_responded ->
        merged = merge_preaccepted(preaccepted)
        {:accept, merged}

      # Some preaccepted but not enough - try TryPreAccept optimization
      preaccept_count >= half_quorum and not leader_responded ->
        merged = merge_preaccepted(preaccepted)
        {:try_preaccept, merged}

      # Some preaccepted - restart phase 1
      preaccept_count > 0 ->
        merged = merge_preaccepted(preaccepted)
        {:restart_phase1, merged}

      # Nobody knows anything
      true ->
        :not_found
    end
  end

  @doc """
  Analyze TryPreAcceptOK responses.

  Returns:
  - `{:accept, possible_quorum}` - Enough OKs to proceed to Accept
  - `{:restart, possible_quorum}` - Too many conflicts, restart Phase 1
  - `{:continue, possible_quorum}` - Need more responses
  """
  def analyze_try_preaccept(responses, cluster_size, possible_quorum) do
    oks = Enum.count(responses, fn r -> r.ok end)

    # Update possible quorum based on conflicts
    possible_quorum =
      Enum.reduce(responses, possible_quorum, fn r, acc ->
        if r.ok do
          acc
        else
          acc
          |> MapSet.delete(r.from)
          |> maybe_delete_conflict(r)
        end
      end)

    not_in_quorum = cluster_size - MapSet.size(possible_quorum)

    cond do
      # Enough OKs - go to Accept
      oks >= Quorum.slow_quorum_size(cluster_size) ->
        {:accept, possible_quorum}

      # Too many not in quorum - restart
      not_in_quorum > div(cluster_size, 2) ->
        {:restart, possible_quorum}

      # Any committed conflict - restart
      Enum.any?(responses, fn r -> not r.ok and r[:conflict_status] == :committed end) ->
        {:restart, possible_quorum}

      # Keep waiting
      true ->
        {:continue, possible_quorum}
    end
  end

  # Private helpers

  defp maybe_delete_conflict(set, %{conflict_replica: nil}), do: set
  defp maybe_delete_conflict(set, %{conflict_replica: r}), do: MapSet.delete(set, r)

  defp fast_path_agreement?(preaccepted, cluster_size) do
    if length(preaccepted) < Quorum.fast_quorum_size(cluster_size) do
      false
    else
      [first | rest] = preaccepted

      Enum.all?(rest, fn r ->
        r.instance.seq == first.instance.seq and
          MapSet.equal?(r.instance.deps, first.instance.deps)
      end)
    end
  end

  defp merge_preaccepted(preaccepted) do
    instances = Enum.map(preaccepted, fn r -> r.instance end)

    base = hd(instances)
    merged_seq = instances |> Enum.map(& &1.seq) |> Enum.max()
    merged_deps = instances |> Enum.map(& &1.deps) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    %{base | seq: merged_seq, deps: merged_deps, status: :accepted}
  end
end
