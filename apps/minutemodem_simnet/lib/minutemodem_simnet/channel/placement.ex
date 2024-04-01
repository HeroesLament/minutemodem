defmodule MinutemodemSimnet.Channel.Placement do
  @moduledoc """
  Horde distribution strategy that places ChannelFSMs on the TX node.

  This minimizes network hops - the channel runs where the transmitter is,
  and only RX delivery crosses the network.
  """

  @behaviour Horde.DistributionStrategy

  require Logger

  @impl true
  def choose_node(identifier, members) do
    Logger.debug("[Placement] choose_node called with identifier: #{inspect(identifier)}")
    Logger.debug("[Placement] members: #{inspect(members)}")

    result = case extract_from_rig(identifier) do
      {:ok, from_rig} ->
        Logger.debug("[Placement] Extracted from_rig: #{inspect(from_rig)}")
        choose_node_for_rig(from_rig, members)

      :error ->
        Logger.debug("[Placement] Could not extract from_rig, using random")
        random_member(members)
    end

    Logger.debug("[Placement] Result: #{inspect(result)}")
    result
  end

  defp extract_from_rig(%{start: {MinutemodemSimnet.Channel.FSM, :start_link, [{from_rig, _to_rig, _params}]}}), do: {:ok, from_rig}
  defp extract_from_rig({MinutemodemSimnet.Channel.FSM, from_rig, _to_rig}), do: {:ok, from_rig}
  defp extract_from_rig(%{id: {MinutemodemSimnet.Channel.FSM, from_rig, _to_rig}}), do: {:ok, from_rig}
  defp extract_from_rig(_), do: :error

  @impl true
  def has_quorum?(_members), do: true

  defp choose_node_for_rig(from_rig, members) do
    # Look up which node the rig is attached from
    case MinutemodemSimnet.Rig.Store.get(from_rig) do
      {:ok, %{node: rig_node}} ->
        Logger.debug("[Placement] Rig #{inspect(from_rig)} is on node #{inspect(rig_node)}")
        # Find member on that node - members are %Horde.DynamicSupervisor.Member{name: {Module, node}}
        case Enum.find(members, fn member ->
          case member do
            %{name: {_, node}} -> node == rig_node
            {_, node} -> node == rig_node
            _ -> false
          end
        end) do
          nil ->
            Logger.debug("[Placement] No member found on #{inspect(rig_node)}, using random")
            random_member(members)
          member ->
            Logger.debug("[Placement] Found member #{inspect(member)} on target node")
            {:ok, member}
        end

      :error ->
        Logger.debug("[Placement] Could not find rig #{inspect(from_rig)}")
        random_member(members)
    end
  end

  defp random_member([]), do: {:error, :no_members}
  defp random_member(members), do: {:ok, Enum.random(members)}
end
