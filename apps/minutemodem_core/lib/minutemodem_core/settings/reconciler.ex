defmodule MinuteModemCore.Settings.Reconciler do
  use GenServer

  require Logger

  alias MinuteModemCore.Control.Router
  alias MinuteModemCore.Settings.Schema
  alias MinuteModemCore.Rig
  alias MinuteModemCore.Rig.Registry

  @name __MODULE__

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  ## ------------------------------------------------------------------
  ## GenServer callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    # Subscribe to router for settings updates
    Router.subscribe_ui(self())

    # Do an initial reconcile on boot
    settings = Router.get_settings()
    reconcile(settings)

    {:ok, %{current_version: settings.version}}
  end

  ## ------------------------------------------------------------------
  ## Message handling
  ## ------------------------------------------------------------------

  @impl true
  def handle_info({:settings_updated, %Schema{} = settings}, state) do
    Logger.info("Reconciling settings version #{settings.version}")
    reconcile(settings)
    {:noreply, %{state | current_version: settings.version}}
  end

  @impl true
  def handle_info({:settings_rolled_back, _version}, state) do
    # Pull authoritative snapshot and reconcile
    settings = Router.get_settings()
    Logger.info("Reconciling after rollback to version #{settings.version}")
    reconcile(settings)
    {:noreply, %{state | current_version: settings.version}}
  end

  # Ignore other router messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## ------------------------------------------------------------------
  ## Reconciliation logic
  ## ------------------------------------------------------------------

  defp reconcile(%Schema{rigs: desired_rigs}) do
    running = Registry.list()
    running_ids = Map.keys(running)
    desired_ids = Map.keys(desired_rigs)

    # ---- Start enabled rigs that aren't running --------------------

    desired_rigs
    |> Enum.filter(fn {_id, cfg} -> cfg.enabled == true end)
    |> Enum.each(fn {rig_id, cfg} ->
      unless rig_id in running_ids do
        Logger.info("Starting rig #{rig_id}")
        Rig.start(Map.put(cfg, :id, rig_id))
      end
    end)

    # ---- Stop running rigs that are now disabled or removed --------

    Enum.each(running_ids, fn rig_id ->
      case desired_rigs[rig_id] do
        %{enabled: true} ->
          :ok

        _ ->
          Logger.info("Stopping rig #{rig_id}")
          Rig.stop(rig_id)
      end
    end)
  end
end
