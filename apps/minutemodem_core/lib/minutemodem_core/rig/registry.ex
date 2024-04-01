defmodule MinuteModemCore.Rig.Registry do
  @moduledoc """
  Rig registry facade.

  Tracks running rig instances and provides lookup.
  Uses an ETS-backed Registry under the hood.

  Note: The actual process registry is `MinuteModemCore.Rig.InstanceRegistry`
  which is started in the application supervisor.
  """

  use GenServer

  alias MinuteModemCore.Persistence.Rigs

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Register a rig instance supervisor pid"
  def register(rig_id, pid) do
    GenServer.cast(__MODULE__, {:register, rig_id, pid})
  end

  @doc "Unregister a rig"
  def unregister(rig_id) do
    GenServer.cast(__MODULE__, {:unregister, rig_id})
  end

  @doc "List running rig IDs"
  def list_running do
    GenServer.call(__MODULE__, :list_running)
  end

  @doc "List all configured rigs from database"
  def list_configured do
    Rigs.list_rigs()
  end

  @doc "Check if a rig is running"
  def running?(rig_id) do
    GenServer.call(__MODULE__, {:running?, rig_id})
  end

  @doc "Get the instance supervisor pid for a rig"
  def get_pid(rig_id) do
    GenServer.call(__MODULE__, {:get_pid, rig_id})
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_) do
    # Map of rig_id => supervisor_pid
    {:ok, %{rigs: %{}}}
  end

  @impl true
  def handle_cast({:register, rig_id, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | rigs: Map.put(state.rigs, rig_id, pid)}}
  end

  @impl true
  def handle_cast({:unregister, rig_id}, state) do
    {:noreply, %{state | rigs: Map.delete(state.rigs, rig_id)}}
  end

  @impl true
  def handle_call(:list_running, _from, state) do
    {:reply, Map.keys(state.rigs), state}
  end

  @impl true
  def handle_call({:running?, rig_id}, _from, state) do
    {:reply, Map.has_key?(state.rigs, rig_id), state}
  end

  @impl true
  def handle_call({:get_pid, rig_id}, _from, state) do
    {:reply, Map.get(state.rigs, rig_id), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and remove the rig that died
    rigs =
      state.rigs
      |> Enum.reject(fn {_id, p} -> p == pid end)
      |> Map.new()

    {:noreply, %{state | rigs: rigs}}
  end
end
