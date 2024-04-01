defmodule WxMVU.Renderer.Intents.Widgets.Slider do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :slider, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for slider #{inspect(widget_id)}")
        state
      else
        min = Keyword.get(opts, :min, 0)
        max = Keyword.get(opts, :max, 100)
        value = Keyword.get(opts, :value, min)
        style = slider_style(opts)

        widget =
          :wxSlider.new(
            parent,
            wxID_ANY(),
            value,
            min,
            max,
            style: style
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_slider_updated)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp slider_style(opts) do
    base = wxSL_HORIZONTAL()

    base = if Keyword.get(opts, :vertical, false), do: wxSL_VERTICAL(), else: base
    base = if Keyword.get(opts, :labels, false), do: Bitwise.bor(base, wxSL_LABELS()), else: base
    base = if Keyword.get(opts, :ticks, false), do: Bitwise.bor(base, wxSL_AUTOTICKS()), else: base
    base = if Keyword.get(opts, :min_max_labels, false), do: Bitwise.bor(base, wxSL_MIN_MAX_LABELS()), else: base

    base
  end
end
