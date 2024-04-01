defmodule WxMVU.Renderer.Intents.Widgets.StaticText do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :static_text, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for widget #{inspect(widget_id)}")
        state
      else
        label = Keyword.get(opts, :label, "")

        widget =
          :wxStaticText.new(
            parent,
            wxID_ANY(),
            label
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_left_click)

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
