defmodule MinuteModemCore.Control.Router do
  use GenServer

  alias MinuteModemCore.Rig
  alias MinuteModemCore.Persistence.Rigs
  alias MinuteModemCore.Persistence.Nets
  alias MinuteModemCore.Persistence.Callsigns
  alias MinuteModemCore.Settings.Manager, as: Settings

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{subscribers: MapSet.new()},
      name: __MODULE__
    )
  end

  # ---- Rig CRUD -----------------------------------------------------

  def create_rig(attrs) do
    GenServer.call(__MODULE__, {:create_rig, attrs})
  end

  def update_rig(rig_id, attrs) do
    GenServer.call(__MODULE__, {:update_rig, rig_id, attrs})
  end

  def delete_rig(rig_id) do
    GenServer.call(__MODULE__, {:delete_rig, rig_id})
  end

  def get_rig(rig_id) do
    GenServer.call(__MODULE__, {:get_rig, rig_id})
  end

  def list_all_rigs do
    GenServer.call(__MODULE__, :list_all_rigs)
  end

  # ---- Net CRUD -------------------------------------------------------

  def list_nets do
    GenServer.call(__MODULE__, :list_nets)
  end

  def create_net(attrs) do
    GenServer.call(__MODULE__, {:create_net, attrs})
  end

  def update_net(net_id, attrs) do
    GenServer.call(__MODULE__, {:update_net, net_id, attrs})
  end

  def delete_net(net_id) do
    GenServer.call(__MODULE__, {:delete_net, net_id})
  end

  def get_net(net_id) do
    GenServer.call(__MODULE__, {:get_net, net_id})
  end

  # ---- Callsign CRUD --------------------------------------------------

  def list_callsigns do
    GenServer.call(__MODULE__, :list_callsigns)
  end

  def create_callsign(attrs) do
    GenServer.call(__MODULE__, {:create_callsign, attrs})
  end

  def update_callsign(callsign_id, attrs) do
    GenServer.call(__MODULE__, {:update_callsign, callsign_id, attrs})
  end

  def delete_callsign(callsign_id) do
    GenServer.call(__MODULE__, {:delete_callsign, callsign_id})
  end

  def get_callsign(callsign_id) do
    GenServer.call(__MODULE__, {:get_callsign, callsign_id})
  end

  def get_callsign_soundings(callsign_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_callsign_soundings, callsign_id, opts})
  end

  # ---- UI subscription ----------------------------------------------

  def subscribe_ui(pid \\ self()) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  def unsubscribe_ui(pid \\ self()) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  # ---- Rig control --------------------------------------------------

  def start_rig(rig_spec) do
    GenServer.call(__MODULE__, {:start_rig, rig_spec})
  end

  def list_rigs do
    GenServer.call(__MODULE__, :list_rigs)
  end

  def set_rig_state(rig_id, state) do
    GenServer.cast(__MODULE__, {:set_rig_state, rig_id, state})
  end

  def list_audio_devices do
    GenServer.call(__MODULE__, :list_audio_devices)
  end

  # ---- Settings passthroughs ----------------------------------------

  def get_settings do
    GenServer.call(__MODULE__, :get_settings)
  end

  def propose_settings(new_settings) do
    GenServer.call(__MODULE__, {:propose_settings, new_settings})
  end

  def rollback_settings(version) do
    GenServer.call(__MODULE__, {:rollback_settings, version})
  end

  ## ------------------------------------------------------------------
  ## GenServer callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  # ---- Calls --------------------------------------------------------

  @impl true
  def handle_call({:start_rig, rig_id}, _from, state) do
    result = Rig.start_by_id(rig_id)
    if match?({:ok, _}, result), do: notify(state.subscribers, :rigs_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_rigs, _from, state) do
    {:reply, MinuteModemCore.Persistence.Rigs.list_rigs(), state}
  end

  @impl true
  def handle_call(:list_audio_devices, _from, state) do
    {:reply, MinuteModemCore.Audio.Manager.list_devices(), state}
  end

  @impl true
  def handle_call({:create_rig, attrs}, _from, state) do
    result = Rigs.create_rig(attrs)
    if match?({:ok, _}, result), do: notify(state.subscribers, :rigs_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_rig, rig_id, attrs}, _from, state) do
    result =
      case Rigs.get_rig!(rig_id) do
        nil -> {:error, :not_found}
        rig -> Rigs.update_rig(rig, attrs)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :rigs_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_rig, rig_id}, _from, state) do
    result =
      case Rigs.get_rig!(rig_id) do
        nil -> {:error, :not_found}
        rig -> Rigs.delete_rig(rig)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :rigs_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_rig, rig_id}, _from, state) do
    {:reply, Rigs.get_rig!(rig_id), state}
  end

  @impl true
  def handle_call(:list_all_rigs, _from, state) do
    {:reply, Rigs.list_rigs(), state}
  end

  @impl true
  def handle_call({:stop_rig, rig_id}, _from, state) do
    result = Rig.stop(rig_id)
    if result == :ok, do: notify(state.subscribers, :rigs_changed)
    {:reply, result, state}
  end

  # ---- Net calls ------------------------------------------------------

  @impl true
  def handle_call(:list_nets, _from, state) do
    {:reply, Nets.list_nets(), state}
  end

  @impl true
  def handle_call({:create_net, attrs}, _from, state) do
    result = Nets.create_net(attrs)
    if match?({:ok, _}, result), do: notify(state.subscribers, :nets_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_net, net_id, attrs}, _from, state) do
    result =
      case Nets.get_net(net_id) do
        nil -> {:error, :not_found}
        net -> Nets.update_net(net, attrs)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :nets_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_net, net_id}, _from, state) do
    result =
      case Nets.get_net(net_id) do
        nil -> {:error, :not_found}
        net -> Nets.delete_net(net)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :nets_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_net, net_id}, _from, state) do
    {:reply, Nets.get_net(net_id), state}
  end

  # ---- Callsign calls -------------------------------------------------

  @impl true
  def handle_call(:list_callsigns, _from, state) do
    {:reply, Callsigns.list_callsigns(), state}
  end

  @impl true
  def handle_call({:create_callsign, attrs}, _from, state) do
    result = Callsigns.create_callsign(attrs)
    if match?({:ok, _}, result), do: notify(state.subscribers, :callsigns_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_callsign, callsign_id, attrs}, _from, state) do
    result =
      case Callsigns.get_callsign(callsign_id) do
        nil -> {:error, :not_found}
        callsign -> Callsigns.update_callsign(callsign, attrs)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :callsigns_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_callsign, callsign_id}, _from, state) do
    result =
      case Callsigns.get_callsign(callsign_id) do
        nil -> {:error, :not_found}
        callsign -> Callsigns.delete_callsign(callsign)
      end
    if match?({:ok, _}, result), do: notify(state.subscribers, :callsigns_changed)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_callsign, callsign_id}, _from, state) do
    {:reply, Callsigns.get_callsign(callsign_id), state}
  end

  @impl true
  def handle_call({:get_callsign_soundings, callsign_id, opts}, _from, state) do
    {:reply, Callsigns.list_soundings(callsign_id, opts), state}
  end

  # ---- Settings calls ----------------------------------------------

  @impl true
  def handle_call(:get_settings, _from, state) do
    {:reply, Settings.current(), state}
  end

  @impl true
  def handle_call({:propose_settings, new_settings}, _from, state) do
    case Settings.propose(new_settings) do
      :ok ->
        current = Settings.current()
        notify(state.subscribers, {:settings_updated, current})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:rollback_settings, version}, _from, state) do
    case Settings.rollback(version) do
      :ok ->
        current = Settings.current()
        notify(state.subscribers, {:settings_updated, current})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ---- Casts --------------------------------------------------------

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)

    # Immediately send authoritative snapshot
    send(pid, {:settings_updated, Settings.current()})

    {:noreply,
     update_in(state.subscribers, &MapSet.put(&1, pid))}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply,
     update_in(state.subscribers, &MapSet.delete(&1, pid))}
  end

  @impl true
  def handle_cast({:set_rig_state, rig_id, rig_state}, state) do
    notify(state.subscribers, {:rig_state, rig_id, rig_state})
    {:noreply, state}
  end

  # ---- Process monitoring ------------------------------------------

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     update_in(state.subscribers, &MapSet.delete(&1, pid))}
  end

  ## ------------------------------------------------------------------
  ## Internal helpers
  ## ------------------------------------------------------------------

  defp notify(subscribers, message) do
    Enum.each(subscribers, fn pid ->
      send(pid, message)
    end)
  end
end
