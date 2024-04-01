defmodule WxMVU.Renderer.Intents.Widgets.Calendar do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :calendar, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for calendar #{inspect(widget_id)}")
        state
      else
        style = calendar_style(opts)

        widget =
          :wxCalendarCtrl.new(
            parent,
            wxID_ANY(),
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

        :wxEvtHandler.connect(widget, :calendar_sel_changed)
        :wxEvtHandler.connect(widget, :calendar_day_changed)
        :wxEvtHandler.connect(widget, :calendar_month_changed)
        :wxEvtHandler.connect(widget, :calendar_year_changed)
        :wxEvtHandler.connect(widget, :calendar_doubleclicked)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp calendar_style(opts) do
    base = 0

    base = if Keyword.get(opts, :sunday_first, false), do: Bitwise.bor(base, wxCAL_SUNDAY_FIRST()), else: Bitwise.bor(base, wxCAL_MONDAY_FIRST())
    base = if Keyword.get(opts, :show_holidays, true), do: Bitwise.bor(base, wxCAL_SHOW_HOLIDAYS()), else: base
    base = if Keyword.get(opts, :no_year_change, false), do: Bitwise.bor(base, wxCAL_NO_YEAR_CHANGE()), else: base
    base = if Keyword.get(opts, :no_month_change, false), do: Bitwise.bor(base, wxCAL_NO_MONTH_CHANGE()), else: base
    base = if Keyword.get(opts, :show_week_numbers, false), do: Bitwise.bor(base, wxCAL_SHOW_WEEK_NUMBERS()), else: base

    base
  end
end
