defmodule MinutemodemSimnet.RxCombiner.Registry do
  @moduledoc """
  Local process registry for RxCombiner processes.

  Uses Elixir's built-in Registry (not Horde) since combiners
  live on the same node as the Attachment that created them.
  Registration is instant — no CRDT propagation delay.
  """

  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def via(rig_id) do
    {:via, Registry, {__MODULE__, rig_id}}
  end

  def lookup(rig_id) do
    case Registry.lookup(__MODULE__, rig_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def all_combiners do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
