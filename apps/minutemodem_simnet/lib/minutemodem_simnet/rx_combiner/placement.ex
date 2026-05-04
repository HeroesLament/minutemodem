defmodule MinutemodemSimnet.RxCombiner.Placement do
  @moduledoc """
  Horde distribution strategy for RxCombiner placement.

  Distributes combiners across simnet cluster nodes for load balancing.
  Uses consistent hashing on rig_id for deterministic placement that
  survives cluster membership changes without redistribution churn.
  """

  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(identifier, members) do
    case members do
      [] ->
        {:error, :no_members}

      members ->
        # Extract rig_id for consistent hashing
        rig_id = extract_rig_id(identifier)
        hash = :erlang.phash2(rig_id, length(members))
        {:ok, Enum.at(members, hash)}
    end
  end

  @impl true
  def has_quorum?(_members), do: true

  defp extract_rig_id(%{start: {MinutemodemSimnet.RxCombiner.Combiner, :start_link, [{rig_id, _opts}]}}),
    do: rig_id

  defp extract_rig_id(%{id: {MinutemodemSimnet.RxCombiner.Combiner, rig_id}}),
    do: rig_id

  defp extract_rig_id(_), do: :rand.uniform(1_000_000)
end
