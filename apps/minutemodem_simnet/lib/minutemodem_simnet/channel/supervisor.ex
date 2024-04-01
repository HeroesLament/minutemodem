defmodule MinutemodemSimnet.Channel.Supervisor do
  @moduledoc """
  Horde.DynamicSupervisor for distributed ChannelFSM processes.

  Each directed channel (A→B) gets its own FSM, placed on the TX node
  via the Placement strategy.
  """
  use Horde.DynamicSupervisor

  alias MinutemodemSimnet.Channel.FSM
  alias MinutemodemSimnet.Channel.Placement

  def start_link(opts \\ []) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Horde.DynamicSupervisor.init(
      strategy: :one_for_one,
      members: :auto,
      distribution_strategy: Placement
    )
  end

  @doc """
  Starts a ChannelFSM for the directed link from→to.
  """
  def start_channel(from_rig, to_rig, params) do
    child_spec = {FSM, {from_rig, to_rig, params}}

    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates a specific channel.
  """
  def terminate_channel(from_rig, to_rig) do
    case MinutemodemSimnet.Channel.Registry.lookup(from_rig, to_rig) do
      {:ok, pid} ->
        Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Terminates all channels. Called during epoch stop.
  """
  def terminate_all do
    __MODULE__
    |> Horde.DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    :ok
  end
end
