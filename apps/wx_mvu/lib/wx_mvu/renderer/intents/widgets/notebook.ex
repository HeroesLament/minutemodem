defmodule WxMVU.Renderer.Intents.Widgets.Notebook do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :notebook, parent_id, _opts}, state) do
    if Map.has_key?(state.notebooks, widget_id) do
      state
    else
      parent =
        Map.get(state.windows, parent_id) ||
          Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for notebook #{inspect(widget_id)}")
        state
      else
        notebook =
          :wxNotebook.new(
            parent,
            wxID_ANY()
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(parent_sizer, notebook, proportion: 1, flag: wxEXPAND())
        :wxWindow.layout(parent)

        :wxEvtHandler.connect(notebook, :command_notebook_page_changed)

        %{
          state
          | notebooks: Map.put(state.notebooks, widget_id, notebook),
            widget_ids: Map.put(state.widget_ids, notebook, widget_id)
        }
      end
    end
  end
end
