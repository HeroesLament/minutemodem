defmodule WxMVU.Renderer.Intents.Widgets.ComboBox do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :combo_box, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for combo_box #{inspect(widget_id)}")
        state
      else
        choices = Keyword.get(opts, :choices, [])
        value = Keyword.get(opts, :value, "")
        style = combo_style(opts)

        widget =
          :wxComboBox.new(
            parent,
            wxID_ANY(),
            value: value,
            choices: Enum.map(choices, &to_string/1),
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

        :wxEvtHandler.connect(widget, :command_combobox_selected)
        :wxEvtHandler.connect(widget, :command_text_updated)
        :wxEvtHandler.connect(widget, :command_text_enter)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp combo_style(opts) do
    base = wxCB_DROPDOWN()

    base = if Keyword.get(opts, :readonly, false), do: wxCB_READONLY(), else: base
    base = if Keyword.get(opts, :sort, false), do: Bitwise.bor(base, wxCB_SORT()), else: base

    base
  end
end
