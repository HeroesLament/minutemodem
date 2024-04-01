defmodule WxMVU.Renderer.Intents.Widgets.StatusBar do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :status_bar, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      # Status bar attaches to a frame (window), not a panel
      window = Map.get(state.windows, parent_id)

      if is_nil(window) do
        Logger.debug("Renderer: window not ready for status_bar #{inspect(widget_id)}")
        state
      else
        fields = Keyword.get(opts, :fields, 1)

        widget = :wxFrame.createStatusBar(window, number: fields)

        # Set field widths if provided
        if widths = Keyword.get(opts, :widths) do
          :wxStatusBar.setFieldsCount(widget, length(widths))
          :wxStatusBar.setStatusWidths(widget, widths)
        end

        # Set initial text if provided
        if text = Keyword.get(opts, :text) do
          :wxStatusBar.setStatusText(widget, text)
        end

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end
end
