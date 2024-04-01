defmodule WxMVU.Renderer.Intents.Widgets.DatePicker do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :date_picker, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for date_picker #{inspect(widget_id)}")
        state
      else
        style = date_picker_style(opts)

        widget =
          :wxDatePickerCtrl.new(
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

        :wxEvtHandler.connect(widget, :date_changed)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp date_picker_style(opts) do
    base = wxDP_DEFAULT()

    base = if Keyword.get(opts, :dropdown, true), do: Bitwise.bor(base, wxDP_DROPDOWN()), else: base
    base = if Keyword.get(opts, :spin, false), do: Bitwise.bor(base, wxDP_SPIN()), else: base
    base = if Keyword.get(opts, :allow_none, false), do: Bitwise.bor(base, wxDP_ALLOWNONE()), else: base
    base = if Keyword.get(opts, :show_century, true), do: Bitwise.bor(base, wxDP_SHOWCENTURY()), else: base

    base
  end
end
