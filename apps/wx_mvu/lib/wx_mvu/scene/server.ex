defmodule WxMVU.Scene.Server do
  @moduledoc """
  GenServer wrapper for scene modules.

  This module handles:
  - Starting the scene as a named process
  - Registering with the Coordinator
  - Receiving UI events and dispatching to the scene's `handle_event/2`
  - Caching intents for the Coordinator to collect
  - Registering widget ownership with ComponentRegistry

  ## Scene Callbacks

  Scenes can implement these callbacks:
  - `init/1` - Initialize the model (required)
  - `view/1` - Return intents for rendering (required)
  - `handle_event/2` - Handle UI events (required)
  - `handle_info/2` - Handle arbitrary messages (optional)

  The `handle_info/2` callback allows scenes to receive messages from
  external processes (like GenStateMachine clients) and update their model
  reactively. It should return `{:noreply, new_model}`.

  Users don't interact with this module directly - they use `WxMVU.start_scene/2`.
  """

  use GenServer
  require Logger

  defstruct [
    :module,
    :model,
    :intents
  ]

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  @doc false
  def start_link({module, args}) do
    GenServer.start_link(__MODULE__, {module, args}, name: module)
  end

  ## ------------------------------------------------------------------
  ## GenServer Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init({module, args}) do
    Logger.debug("Scene.Server: starting #{inspect(module)}")

    # Call the scene's init callback
    model = module.init(args)

    # Compute initial intents
    intents = module.view(model)

    # Register widgets with ComponentRegistry
    register_widgets(intents)

    # Register with Coordinator (triggers initial render)
    WxMVU.Coordinator.register_scene(self(), module)

    {:ok, %__MODULE__{module: module, model: model, intents: intents}}
  end

  @impl true
  def handle_info({:ui_event, _widget_id, _event_type} = event, state) do
    Logger.debug("Scene.Server(#{inspect(state.module)}): received #{inspect(event)}")
    handle_scene_event(event, state)
  end

  def handle_info({:ui_event, _widget_id, _event_type, _data} = event, state) do
    Logger.debug("Scene.Server(#{inspect(state.module)}): received #{inspect(event)}")
    handle_scene_event(event, state)
  end

  def handle_info({:dialog_result, _dialog_id, _result} = event, state) do
    Logger.debug("Scene.Server(#{inspect(state.module)}): received #{inspect(event)}")
    handle_scene_event(event, state)
  end

  def handle_info(msg, state) do
    # Check if the scene module implements handle_info/2
    if function_exported?(state.module, :handle_info, 2) do
      handle_scene_info(msg, state)
    else
      Logger.debug("Scene.Server(#{inspect(state.module)}): ignoring #{inspect(msg)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_intents, _from, state) do
    {:reply, state.intents, state}
  end

  def handle_call(:get_model, _from, state) do
    {:reply, state.model, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Scene.Server(#{inspect(state.module)}): terminating: #{inspect(reason)}")
    WxMVU.Coordinator.unregister_scene(self())
    :ok
  end

  ## ------------------------------------------------------------------
  ## Private Functions
  ## ------------------------------------------------------------------

  defp handle_scene_event(event, state) do
    # Call the scene's handle_event callback
    new_model = state.module.handle_event(event, state.model)

    if new_model == state.model do
      # Model unchanged, no re-render needed
      {:noreply, state}
    else
      # Model changed, recompute intents
      new_intents = state.module.view(new_model)

      # Re-register widgets (in case new widgets were added)
      register_widgets(new_intents)

      # Notify coordinator to schedule a render
      WxMVU.Coordinator.notify_dirty()

      {:noreply, %{state | model: new_model, intents: new_intents}}
    end
  end

  defp handle_scene_info(msg, state) do
    # Call the scene's handle_info callback
    case state.module.handle_info(msg, state.model) do
      {:noreply, new_model} ->
        if new_model == state.model do
          {:noreply, state}
        else
          # Model changed, recompute intents
          new_intents = state.module.view(new_model)
          register_widgets(new_intents)
          WxMVU.Coordinator.notify_dirty()
          {:noreply, %{state | model: new_model, intents: new_intents}}
        end

      {:stop, reason, new_model} ->
        {:stop, reason, %{state | model: new_model}}

      other ->
        Logger.warning("Scene.Server(#{inspect(state.module)}): handle_info returned unexpected: #{inspect(other)}")
        {:noreply, state}
    end
  end

  defp register_widgets(intents) do
    pid = self()

    Enum.each(intents, fn
      {:ensure_widget, widget_id, _, _, _} ->
        WxMVU.Renderer.ComponentRegistry.register(widget_id, pid)

      {:ensure_panel, panel_id, _, _} ->
        WxMVU.Renderer.ComponentRegistry.register(panel_id, pid)

      {:ensure_window, window_id, _} ->
        WxMVU.Renderer.ComponentRegistry.register(window_id, pid)

      _ ->
        :ok
    end)
  end
end
