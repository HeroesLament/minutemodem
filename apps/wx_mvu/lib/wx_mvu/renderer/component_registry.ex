defmodule WxMVU.Renderer.ComponentRegistry do
  @moduledoc """
  Registry mapping widget_id -> owning component process.

  Renderer uses this to route UI events back to the correct process.
  """

  use GenServer

  @table __MODULE__

  ## ------------------------------------------------------------------
  ## Supervision
  ## ------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  ## ------------------------------------------------------------------
  ## GenServer
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  @spec register(term(), pid()) :: :ok
  def register(widget_id, pid) when is_pid(pid) do
    :ets.insert(@table, {widget_id, pid})
    :ok
  end

  @spec unregister(term()) :: :ok
  def unregister(widget_id) do
    :ets.delete(@table, widget_id)
    :ok
  end

  @spec lookup(term()) :: pid() | nil
  def lookup(widget_id) do
    case :ets.lookup(@table, widget_id) do
      [{^widget_id, pid}] -> pid
      _ -> nil
    end
  end
end
