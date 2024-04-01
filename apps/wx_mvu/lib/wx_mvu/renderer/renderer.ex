defmodule WxMVU.Renderer do
  @moduledoc """
  Owns the wx environment and applies declarative render intents.

  This is the ONLY module allowed to call wx APIs.
  """

  use GenServer
  use WxEx

  require Logger

  alias WxMVU.Event
  alias WxMVU.Renderer.ComponentRegistry
  alias WxMVU.Renderer.Intents

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def render(intent) do
    GenServer.cast(__MODULE__, {:render, intent})
  end

  def set_theme(theme_module) do
    GenServer.call(__MODULE__, {:set_theme, theme_module})
  end

  def get_theme do
    GenServer.call(__MODULE__, :get_theme)
  end

  ## ------------------------------------------------------------------
  ## Lifecycle
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    wx = :wx.new()

    # Initialize OpenGL NIF - required on macOS 26+ where on_load doesn't work automatically
    init_opengl_nif()

    mode = detect_mode()

    {:ok,
     %{
       wx: wx,
       windows: %{},
       panels: %{},
       widgets: %{},
       notebooks: %{},
       sizers: %{},
       widget_ids: %{},
       theme: WxMVU.Theme,
       mode: mode
     }}
  end

  ## ------------------------------------------------------------------
  ## GenServer callbacks
  ## ------------------------------------------------------------------

  @impl true
  def handle_cast({:render, intent}, state) do
    Logger.debug("Renderer intent: #{inspect(intent)}")
    {:noreply, Intents.apply(intent, state)}
  end

  @impl true
  def handle_call({:set_theme, theme_module}, _from, state) do
    {:reply, :ok, %{state | theme: theme_module}}
  end

  @impl true
  def handle_call(:get_theme, _from, state) do
    {:reply, {state.theme, state.mode}, state}
  end

  @impl true
  def handle_info({:wx, _, source, event}, state) do
    Logger.debug("Renderer wx event: source=#{inspect(source)} event=#{inspect(event)}")
    handle_wx_event(source, event, state)
  end

  def handle_info({:wx, _, source, _user_data, event}, state) do
    Logger.debug("Renderer wx event (with user_data): source=#{inspect(source)} event=#{inspect(event)}")
    handle_wx_event(source, event, state)
  end

  def handle_info({:dialog_result, _dialog_id, _result} = event, state) do
    WxMVU.Coordinator.broadcast_event(event)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Renderer unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_wx_event(source, event, state) do
    case Map.get(state.widget_ids, source) do
      nil ->
        Logger.debug("Renderer: no widget_id for source #{inspect(source)}")
        {:noreply, state}

      {:gl_canvas, _canvas_id} = widget_id ->
        # GL canvas events - route to canvas server
        handle_gl_canvas_event(widget_id, source, event, state)

      widget_id ->
        # Regular widget events
        handle_regular_widget_event(widget_id, source, event, state)
    end
  end

  defp handle_regular_widget_event(widget_id, source, event, state) do
    ui_event = Event.from_wx(widget_id, {:wx, nil, source, event})
    Logger.debug("Renderer: translated to #{inspect(ui_event)}")

    case ComponentRegistry.lookup(widget_id) do
      nil ->
        Logger.debug("Renderer: no component registered for #{inspect(widget_id)}")

      pid ->
        Logger.debug("Renderer: sending to #{inspect(pid)}")
        send(pid, ui_event)
    end

    {:noreply, state}
  end

  defp handle_gl_canvas_event(widget_id, source, event, state) do
    case ComponentRegistry.lookup(widget_id) do
      nil ->
        Logger.debug("Renderer: no GL canvas server for #{inspect(widget_id)}")
        {:noreply, state}

      pid ->
        gl_event = translate_gl_canvas_event(source, event)

        if gl_event do
          Logger.debug("Renderer: sending GL event to #{inspect(pid)}: #{inspect(gl_event)}")
          send(pid, gl_event)
        end

        {:noreply, state}
    end
  end

  # Resize event
  defp translate_gl_canvas_event(source, {:wxSize, :size, size, _rect}) do
    logical_size = size
    dpi_scale = get_dpi_scale(source)
    {lw, lh} = logical_size
    pixel_size = {trunc(lw * dpi_scale), trunc(lh * dpi_scale)}

    {:wx_resize, logical_size, pixel_size, dpi_scale}
  end

  # Mouse move
  defp translate_gl_canvas_event(_source, {:wxMouse, :motion, x, y, _, _, _, _, _, _, _, _}) do
    {:wx_mouse, :move, x, y, nil, nil, []}
  end

  # Mouse button down
  defp translate_gl_canvas_event(_source, {:wxMouse, :left_down, x, y, left, middle, right, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :down, x, y, :left, nil, modifiers(ctrl, shift, alt, meta)}
  end

  defp translate_gl_canvas_event(_source, {:wxMouse, :middle_down, x, y, _, _, _, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :down, x, y, :middle, nil, modifiers(ctrl, shift, alt, meta)}
  end

  defp translate_gl_canvas_event(_source, {:wxMouse, :right_down, x, y, _, _, _, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :down, x, y, :right, nil, modifiers(ctrl, shift, alt, meta)}
  end

  # Mouse button up
  defp translate_gl_canvas_event(_source, {:wxMouse, :left_up, x, y, _, _, _, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :up, x, y, :left, nil, modifiers(ctrl, shift, alt, meta)}
  end

  defp translate_gl_canvas_event(_source, {:wxMouse, :middle_up, x, y, _, _, _, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :up, x, y, :middle, nil, modifiers(ctrl, shift, alt, meta)}
  end

  defp translate_gl_canvas_event(_source, {:wxMouse, :right_up, x, y, _, _, _, ctrl, shift, alt, meta, _}) do
    {:wx_mouse, :up, x, y, :right, nil, modifiers(ctrl, shift, alt, meta)}
  end

  # Mouse wheel
  defp translate_gl_canvas_event(_source, {:wxMouse, :mousewheel, x, y, _, _, _, ctrl, shift, alt, meta, wheel_rotation}) do
    {:wx_mouse, :wheel, x, y, nil, wheel_rotation, modifiers(ctrl, shift, alt, meta)}
  end

  # Mouse enter/leave
  defp translate_gl_canvas_event(_source, {:wxMouse, :enter_window, x, y, _, _, _, _, _, _, _, _}) do
    {:wx_mouse, :enter, x, y, nil, nil, []}
  end

  defp translate_gl_canvas_event(_source, {:wxMouse, :leave_window, x, y, _, _, _, _, _, _, _, _}) do
    {:wx_mouse, :leave, x, y, nil, nil, []}
  end

  # Key events
  defp translate_gl_canvas_event(_source, {:wxKey, :key_down, keycode, _, ctrl, shift, alt, meta, unicode_char, _raw}) do
    char = if unicode_char > 0, do: <<unicode_char::utf8>>, else: nil
    {:wx_key, :down, keycode, char, modifiers(ctrl, shift, alt, meta)}
  end

  defp translate_gl_canvas_event(_source, {:wxKey, :key_up, keycode, _, ctrl, shift, alt, meta, unicode_char, _raw}) do
    char = if unicode_char > 0, do: <<unicode_char::utf8>>, else: nil
    {:wx_key, :up, keycode, char, modifiers(ctrl, shift, alt, meta)}
  end

  # Focus events
  defp translate_gl_canvas_event(_source, {:wxFocus, :set_focus, _}) do
    {:wx_focus, :gained}
  end

  defp translate_gl_canvas_event(_source, {:wxFocus, :kill_focus, _}) do
    {:wx_focus, :lost}
  end

  # Paint event - just triggers a render, no data needed
  defp translate_gl_canvas_event(_source, {:wxPaint, :paint}) do
    :request_render
  end

  # Unknown event
  defp translate_gl_canvas_event(_source, event) do
    Logger.debug("Renderer: unhandled GL canvas event #{inspect(event)}")
    nil
  end

  defp modifiers(ctrl, shift, alt, meta) do
    []
    |> maybe_add(:ctrl, ctrl)
    |> maybe_add(:shift, shift)
    |> maybe_add(:alt, alt)
    |> maybe_add(:meta, meta)
  end

  defp maybe_add(list, key, true), do: [key | list]
  defp maybe_add(list, _key, _), do: list

  defp get_dpi_scale(source) do
    try do
      :wxWindow.getContentScaleFactor(source)
    rescue
      _ -> 1.0
    catch
      _, _ -> 1.0
    end
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp init_opengl_nif do
    # On macOS 26+, the gl module's on_load doesn't fire automatically.
    # We need to explicitly initialize the NIF before using any GL functions.
    try do
      :gl.init_nif()
      :wxe_master.init_opengl()
      Logger.debug("Renderer: OpenGL NIF initialized")
    catch
      _, _ ->
        Logger.warning("Renderer: OpenGL NIF initialization failed - GL canvases may not work")
    end
  end

  defp detect_mode do
    {r, g, b, _a} = :wxSystemSettings.getColour(5)
    avg = div(r + g + b, 3)
    if avg > 128, do: :light, else: :dark
  end
end
