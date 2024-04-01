defmodule WxMVU.Renderer.Intents.Widgets.ScrolledWindow do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :scrolled_window, parent_id, opts}, state) do
    if Map.has_key?(state.panels, widget_id) do
      state
    else
      parent =
        Map.get(state.windows, parent_id) ||
          Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for scrolled_window #{inspect(widget_id)}")
        state
      else
        style = Keyword.get(opts, :style, Bitwise.bor(wxVSCROLL(), wxHSCROLL()))

        widget = :wxScrolledWindow.new(parent, id: wxID_ANY(), style: style)

        # Set scroll rate
        scroll_rate_x = Keyword.get(opts, :scroll_rate_x, 10)
        scroll_rate_y = Keyword.get(opts, :scroll_rate_y, 10)
        :wxScrolledWindow.setScrollRate(widget, scroll_rate_x, scroll_rate_y)

        # Create inner sizer for content
        sizer = :wxBoxSizer.new(wxVERTICAL())
        :wxScrolledWindow.setSizer(widget, sizer)

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        proportion = Keyword.get(opts, :proportion, 1)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: proportion,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxWindow.layout(parent)

        # Store as panel so children can be added
        %{
          state
          | panels: Map.put(state.panels, widget_id, widget),
            sizers: Map.put(state.sizers, widget_id, sizer),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  # Set virtual size (scrollable area)
  def apply({:scroll_set_virtual_size, widget_id, width, height}, state) do
    widget = Map.get(state.panels, widget_id)

    if widget do
      :wxScrolledWindow.setVirtualSize(widget, width, height)
      :wxScrolledWindow.fitInside(widget)
    end

    state
  end

  # Scroll to position
  def apply({:scroll_to, widget_id, x, y}, state) do
    widget = Map.get(state.panels, widget_id)

    if widget do
      :wxScrolledWindow.scroll(widget, x, y)
    end

    state
  end
end
