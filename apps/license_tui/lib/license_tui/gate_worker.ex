defmodule LicenseTUI.GateWorker do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    {:ok, Map.new(opts), {:continue, :check}}
  end

  def handle_continue(:check, state) do
    Process.sleep(200)
    LicenseTUI.Gate.require_license!()

    for child_spec <- state.children do
      DynamicSupervisor.start_child(state.supervisor, child_spec)
    end

    {:noreply, state}
  end
end
