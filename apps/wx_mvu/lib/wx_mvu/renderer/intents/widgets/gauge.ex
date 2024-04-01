defmodule WxMVU.Renderer.Intents.Widgets.Gauge do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :gauge, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for gauge #{inspect(widget_id)}")
        state
      else
        range = Keyword.get(opts, :range, 100)
        value = Keyword.get(opts, :value, 0)
        style = gauge_style(opts)

        widget =
          :wxGauge.new(
            parent,
            wxID_ANY(),
            range,
            style: style
          )

        :wxGauge.setValue(widget, value)

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp gauge_style(opts) do
    base = if Keyword.get(opts, :vertical, false), do: wxGA_VERTICAL(), else: wxGA_HORIZONTAL()
    base = if Keyword.get(opts, :smooth, true), do: Bitwise.bor(base, wxGA_SMOOTH()), else: base

    base
  end
end
