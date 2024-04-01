defmodule MinutemodemSimnet.Channel.Registry do
  @moduledoc """
  Horde.Registry for distributed ChannelFSM lookup.

  Channels are keyed by {from_rig, to_rig} tuples.
  """
  use Horde.Registry

  def start_link(_opts) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  @impl true
  def init(init_arg) do
    [members: members()]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end

  defp members do
    [Node.self() | Node.list()]
    |> Enum.map(fn node -> {__MODULE__, node} end)
  end

  @doc """
  Returns the via tuple for a channel FSM.
  """
  def via(from_rig, to_rig) do
    {:via, Horde.Registry, {__MODULE__, {from_rig, to_rig}}}
  end

  @doc """
  Looks up a channel FSM by from/to rigs.
  """
  def lookup(from_rig, to_rig) do
    case Horde.Registry.lookup(__MODULE__, {from_rig, to_rig}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns all registered channels.
  """
  def all_channels do
    Horde.Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end
end
