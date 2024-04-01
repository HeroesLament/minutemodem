defmodule MinuteModemCore.Persistence.Nets do
  @moduledoc """
  Persistence API for ALE networks.
  """

  import Ecto.Query

  alias MinuteModemCore.Persistence.Repo
  alias MinuteModemCore.Persistence.Schemas.Net

  def list_nets do
    Repo.all(Net)
  end

  def list_enabled_nets do
    Repo.all(from n in Net, where: n.enabled == true)
  end

  def get_net(id) do
    Repo.get(Net, id)
  end

  def get_net!(id) do
    Repo.get!(Net, id)
  end

  def get_net_by_name(name) do
    Repo.get_by(Net, name: name)
  end

  def create_net(attrs) do
    %Net{}
    |> Net.changeset(attrs)
    |> Repo.insert()
  end

  def update_net(%Net{} = net, attrs) do
    net
    |> Net.changeset(attrs)
    |> Repo.update()
  end

  def delete_net(%Net{} = net) do
    Repo.delete(net)
  end

  def add_channel(%Net{} = net, channel) when is_map(channel) do
    channels = net.channels ++ [channel]
    update_net(net, %{channels: channels})
  end

  def remove_channel(%Net{} = net, index) when is_integer(index) do
    channels = List.delete_at(net.channels, index)
    update_net(net, %{channels: channels})
  end

  def update_channel(%Net{} = net, index, channel) when is_integer(index) and is_map(channel) do
    channels = List.replace_at(net.channels, index, channel)
    update_net(net, %{channels: channels})
  end

  def add_member(%Net{} = net, member) when is_map(member) do
    members = net.members ++ [member]
    update_net(net, %{members: members})
  end

  def remove_member(%Net{} = net, index) when is_integer(index) do
    members = List.delete_at(net.members, index)
    update_net(net, %{members: members})
  end

  def update_member(%Net{} = net, index, member) when is_integer(index) and is_map(member) do
    members = List.replace_at(net.members, index, member)
    update_net(net, %{members: members})
  end
end
