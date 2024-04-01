defmodule WxMVU.Coordinator do
  @moduledoc """
  Coordinates rendering across multiple scene processes.

  Responsibilities:
  - Tracks registered scenes
  - Batches dirty notifications (coalesces rapid updates)
  - Collects intents from all scenes
  - Performs topological sort
  - Diffs against previous intents
  - Sends only changes to Renderer

  ## Batching

  When a scene calls `notify_dirty/0`, the Coordinator schedules a render
  on the next tick. Multiple dirty notifications within the same tick
  are coalesced into a single render pass.
  """

  use GenServer
  require Logger

  defstruct [
    scenes: %{},
    previous_intents: [],
    render_scheduled: false
  ]

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Registers a scene process with the coordinator.

  Called automatically by `WxMVU.Scene.Server` on init.
  """
  @spec register_scene(pid(), module()) :: :ok
  def register_scene(pid, module) do
    GenServer.call(__MODULE__, {:register, pid, module})
  end

  @doc """
  Unregisters a scene process.

  Called automatically when a scene terminates.
  """
  @spec unregister_scene(pid()) :: :ok
  def unregister_scene(pid) do
    GenServer.cast(__MODULE__, {:unregister, pid})
  end

  @doc """
  Notifies the coordinator that a scene's state has changed.

  This schedules a batched render on the next tick.
  """
  @spec notify_dirty() :: :ok
  def notify_dirty do
    GenServer.cast(__MODULE__, :dirty)
  end

  @doc """
  Forces an immediate render pass.

  Useful for testing or initial render.
  """
  @spec force_render() :: :ok
  def force_render do
    GenServer.cast(__MODULE__, :force_render)
  end

  @doc """
  Broadcasts an event to all registered scenes.
  """
  @spec broadcast_event(term()) :: :ok
  def broadcast_event(event) do
    GenServer.cast(__MODULE__, {:broadcast, event})
  end

  ## ------------------------------------------------------------------
  ## GenServer Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, pid, module}, _from, state) do
    Logger.debug("Coordinator: registering scene #{inspect(module)} (#{inspect(pid)})")
    Process.monitor(pid)
    new_scenes = Map.put(state.scenes, pid, module)
    new_state = schedule_render(%{state | scenes: new_scenes})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:unregister, pid}, state) do
    Logger.debug("Coordinator: unregistering scene #{inspect(pid)}")
    new_scenes = Map.delete(state.scenes, pid)
    new_state = schedule_render(%{state | scenes: new_scenes})
    {:noreply, new_state}
  end

  def handle_cast(:dirty, state) do
    {:noreply, schedule_render(state)}
  end

  def handle_cast(:force_render, state) do
    new_intents = collect_and_render(state)
    {:noreply, %{state | previous_intents: new_intents, render_scheduled: false}}
  end

  def handle_cast({:broadcast, event}, state) do
    Enum.each(state.scenes, fn {pid, _module} ->
      send(pid, event)
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:render, state) do
    new_intents = collect_and_render(state)
    {:noreply, %{state | previous_intents: new_intents, render_scheduled: false}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.debug("Coordinator: scene #{inspect(pid)} went down: #{inspect(reason)}")
    new_scenes = Map.delete(state.scenes, pid)
    new_state = schedule_render(%{state | scenes: new_scenes})
    {:noreply, new_state}
  end

  ## ------------------------------------------------------------------
  ## Private Functions
  ## ------------------------------------------------------------------

  defp schedule_render(%{render_scheduled: true} = state), do: state

  defp schedule_render(state) do
    send(self(), :render)
    %{state | render_scheduled: true}
  end

  defp collect_and_render(state) do
    if map_size(state.scenes) == 0 do
      Logger.debug("Coordinator: no scenes registered, skipping render")
      []
    else
      intents =
        state.scenes
        |> Enum.flat_map(fn {pid, _module} ->
          try do
            GenServer.call(pid, :get_intents, 5000)
          catch
            :exit, _ ->
              Logger.warning("Coordinator: failed to get intents from #{inspect(pid)}")
              []
          end
        end)
        |> topo_sort()

      changes = WxMVU.Diff.compute(state.previous_intents, intents)

      Logger.debug("Coordinator: #{length(state.previous_intents)} prev, #{length(intents)} new, #{length(changes)} changes")

      Enum.each(changes, &WxMVU.Renderer.render/1)

      intents
    end
  end

  ## ------------------------------------------------------------------
  ## Topological Sort
  ## ------------------------------------------------------------------

  defp topo_sort(intents) do
    {ensure_intents, other_intents} = Enum.split_with(intents, &ensure_intent?/1)
    {refresh_intents, action_intents} = Enum.split_with(other_intents, &refresh_intent?/1)

    sorted_ensures = topo_sort_ensures(ensure_intents)

    sorted_ensures ++ action_intents ++ refresh_intents
  end

  defp ensure_intent?({:ensure_window, _, _}), do: true
  defp ensure_intent?({:ensure_panel, _, _, _}), do: true
  defp ensure_intent?({:ensure_widget, _, _, _, _}), do: true
  defp ensure_intent?({:ensure_gl_canvas, _, _, _}), do: true
  defp ensure_intent?(_), do: false

  defp refresh_intent?({:refresh, _}), do: true
  defp refresh_intent?(_), do: false

  defp intent_id({:ensure_window, id, _}), do: id
  defp intent_id({:ensure_panel, id, _, _}), do: id
  defp intent_id({:ensure_widget, id, _, _, _}), do: id
  defp intent_id({:ensure_gl_canvas, id, _, _}), do: {:gl_canvas, id}

  defp intent_parent({:ensure_window, _, _}), do: nil
  defp intent_parent({:ensure_panel, _, parent_id, _}), do: parent_id
  defp intent_parent({:ensure_widget, _, _, parent_id, _}), do: parent_id
  defp intent_parent({:ensure_gl_canvas, _, parent_id, _}), do: parent_id

  defp topo_sort_ensures(intents) do
    id_to_intent = Map.new(intents, fn intent -> {intent_id(intent), intent} end)
    all_ids = MapSet.new(Map.keys(id_to_intent))

    in_degree =
      Map.new(intents, fn intent ->
        id = intent_id(intent)
        parent = intent_parent(intent)
        deg = if parent && MapSet.member?(all_ids, parent), do: 1, else: 0
        {id, deg}
      end)

    children =
      Enum.reduce(intents, %{}, fn intent, acc ->
        parent = intent_parent(intent)

        if parent && MapSet.member?(all_ids, parent) do
          id = intent_id(intent)
          Map.update(acc, parent, [id], &[id | &1])
        else
          acc
        end
      end)

    queue = for {id, 0} <- in_degree, do: id

    kahn_sort(queue, in_degree, children, id_to_intent, [])
  end

  defp kahn_sort([], _in_degree, _children, _id_to_intent, acc) do
    Enum.reverse(acc)
  end

  defp kahn_sort([id | rest], in_degree, children, id_to_intent, acc) do
    intent = Map.fetch!(id_to_intent, id)
    child_ids = Map.get(children, id, [])

    {new_in_degree, new_queue_additions} =
      Enum.reduce(child_ids, {in_degree, []}, fn child_id, {deg_map, additions} ->
        new_deg = deg_map[child_id] - 1
        new_deg_map = Map.put(deg_map, child_id, new_deg)
        new_additions = if new_deg == 0, do: [child_id | additions], else: additions
        {new_deg_map, new_additions}
      end)

    new_queue = rest ++ new_queue_additions

    kahn_sort(new_queue, new_in_degree, children, id_to_intent, [intent | acc])
  end
end
