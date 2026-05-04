defmodule MinutemodemSimnet.RxCombiner.Supervisor do
  @moduledoc """
  DynamicSupervisor for RxCombiner processes.

  Each receiving rig gets one combiner, started locally on
  the same node as the Attachment that requested it.
  """

  use DynamicSupervisor

  alias MinutemodemSimnet.RxCombiner.{Combiner, Registry}

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_combiner(rig_id, opts) do
    child_spec = {Combiner, {rig_id, opts}}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def terminate_combiner(rig_id) do
    case Registry.lookup(rig_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        :ok
    end
  end

  def terminate_all do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    :ok
  end
end
