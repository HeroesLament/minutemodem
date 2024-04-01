defmodule MinuteModemClient.Canvas.LED do
  @moduledoc """
  Simple LED indicator using OpenGL.

  A dirt-simple GL canvas that just clears to a color.
  Demonstrates the GLCanvas lifecycle without any shader complexity.

  ## Usage

      # In your scene's view:
      {:ensure_gl_canvas, :tx_led, :my_panel,
        module: MinuteModemClient.Canvas.LED,
        size: {24, 24},
        opts: [color: :green]}

      # Control it:
      WxMVU.GLCanvas.send_data(:tx_led, :on)
      WxMVU.GLCanvas.send_data(:tx_led, :off)
      WxMVU.GLCanvas.send_data(:tx_led, {:blink, 500})  # 500ms interval
      WxMVU.GLCanvas.send_data(:tx_led, :stop_blink)

  ## Options

  - `:color` - Base color: `:red`, `:green`, `:yellow`, `:blue` (default: `:green`)
  - `:initial` - Initial state: `:on`, `:off` (default: `:off`)
  """

  use WxMVU.GLCanvas

  alias WxMVU.Renderer.GL

  # Color definitions: {on_color, off_color}
  @colors %{
    red:    {{1.0, 0.2, 0.2}, {0.3, 0.1, 0.1}},
    green:  {{0.2, 1.0, 0.2}, {0.1, 0.3, 0.1}},
    yellow: {{1.0, 1.0, 0.2}, {0.3, 0.3, 0.1}},
    blue:   {{0.2, 0.4, 1.0}, {0.1, 0.15, 0.3}}
  }

  @impl true
  def init(ctx, opts) do
    color = Keyword.get(opts, :color, :green)
    initial = Keyword.get(opts, :initial, :off)

    {w, h} = ctx.pixel_size
    GL.viewport(0, 0, w, h)

    state = %{
      pixel_size: ctx.pixel_size,
      color: color,
      lit: initial == :on,
      blink_interval: nil,
      blink_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_event(%Resize{pixel_size: {w, h} = size}, state) do
    GL.viewport(0, 0, w, h)
    {:noreply, %{state | pixel_size: size}}
  end

  @impl true
  def handle_event(_event, state) do
    {:noreply, state}
  end

  @impl true
  def handle_data(:on, state) do
    state = cancel_blink(state)
    {:noreply, %{state | lit: true}}
  end

  def handle_data(:off, state) do
    state = cancel_blink(state)
    {:noreply, %{state | lit: false}}
  end

  def handle_data(:toggle, state) do
    {:noreply, %{state | lit: not state.lit}}
  end

  def handle_data({:blink, interval_ms}, state) do
    state = cancel_blink(state)
    ref = schedule_blink(interval_ms)
    {:noreply, %{state | blink_interval: interval_ms, blink_ref: ref}}
  end

  def handle_data(:stop_blink, state) do
    state = cancel_blink(state)
    {:noreply, state}
  end

  def handle_data({:color, color}, state) when is_atom(color) do
    {:noreply, %{state | color: color}}
  end

  def handle_data(:blink_tick, state) do
    # Toggle and schedule next
    ref = if state.blink_interval do
      schedule_blink(state.blink_interval)
    else
      nil
    end
    {:noreply, %{state | lit: not state.lit, blink_ref: ref}}
  end

  def handle_data(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def render(state) do
    {r, g, b} = current_color(state)
    GL.clear_color(r, g, b, 1.0)
    GL.clear(:color)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_blink(state)
    :ok
  end

  # Private helpers

  defp current_color(%{color: color, lit: lit}) do
    {on_color, off_color} = Map.get(@colors, color, @colors.green)
    if lit, do: on_color, else: off_color
  end

  defp schedule_blink(interval_ms) do
    # Send to self via the GLCanvas data path
    Process.send_after(self(), {:gl_data, :blink_tick}, interval_ms)
  end

  defp cancel_blink(%{blink_ref: nil} = state), do: state
  defp cancel_blink(%{blink_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | blink_ref: nil, blink_interval: nil}
  end
end
