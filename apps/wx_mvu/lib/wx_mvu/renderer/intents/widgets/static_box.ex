defmodule WxMVU.Renderer.Intents.Widgets.StaticBox do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :static_box, parent_id, opts}, state) do
    if Map.has_key?(state.panels, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for static_box #{inspect(widget_id)}")
        state
      else
        label = Keyword.get(opts, :label, "")

        box = :wxStaticBox.new(parent, wxID_ANY(), label)
        sizer = :wxStaticBoxSizer.new(box, wxVERTICAL())

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          sizer,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxWindow.layout(parent)

        # Store in panels so children can find it as a parent
        # The actual parent window for children is still `parent`
        %{
          state
          | panels: Map.put(state.panels, widget_id, parent),
            sizers: Map.put(state.sizers, widget_id, sizer),
            widgets: Map.put(state.widgets, widget_id, box),
            widget_ids: Map.put(state.widget_ids, box, widget_id)
        }
      end
    end
  end
end
