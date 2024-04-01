defmodule WxMVU.Renderer.Intents.Widgets.RadioBox do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :radio_box, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for radio_box #{inspect(widget_id)}")
        state
      else
        label = Keyword.get(opts, :label, "")
        choices = Keyword.get(opts, :choices, [])
        major_dimension = Keyword.get(opts, :columns, 1)
        style = if Keyword.get(opts, :horizontal, false), do: wxRA_SPECIFY_COLS(), else: wxRA_SPECIFY_ROWS()

        widget =
          :wxRadioBox.new(
            parent,
            wxID_ANY(),
            label,
            {-1, -1},
            {-1, -1},
            Enum.map(choices, &to_string/1),
            majorDimension: major_dimension,
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

        :wxEvtHandler.connect(widget, :command_radiobox_selected)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end
end
