defmodule WxMVU.Renderer.Intents.Widgets.Checkbox do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :checkbox, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for checkbox #{inspect(widget_id)}")
        state
      else
        label = Keyword.get(opts, :label, "")
        value = Keyword.get(opts, :value, false)

        widget =
          :wxCheckBox.new(
            parent,
            wxID_ANY(),
            label
          )

        :wxCheckBox.setValue(widget, value)

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_checkbox_clicked)

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
