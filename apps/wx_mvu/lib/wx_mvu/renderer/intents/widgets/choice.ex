defmodule WxMVU.Renderer.Intents.Widgets.Choice do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :choice, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for choice #{inspect(widget_id)}")
        state
      else
        choices = Keyword.get(opts, :choices, [])

        widget =
          :wxChoice.new(
            parent,
            wxID_ANY(),
            choices: Enum.map(choices, &to_string/1)
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_choice_selected)

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
