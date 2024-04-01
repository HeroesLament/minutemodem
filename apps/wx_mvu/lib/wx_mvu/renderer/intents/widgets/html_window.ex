defmodule WxMVU.Renderer.Intents.Widgets.HtmlWindow do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :html_window, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for html_window #{inspect(widget_id)}")
        state
      else
        widget =
          :wxHtmlWindow.new(
            parent,
            id: wxID_ANY()
          )

        # Set initial content if provided
        if html = Keyword.get(opts, :html) do
          :wxHtmlWindow.setPage(widget, html)
        end

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        proportion = Keyword.get(opts, :proportion, 1)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: proportion,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_html_link_clicked)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  # Set HTML content
  def apply({:html_set_page, widget_id, html}, state) do
    widget = Map.get(state.widgets, widget_id)

    if widget do
      :wxHtmlWindow.setPage(widget, html)
    end

    state
  end

  # Load URL
  def apply({:html_load_page, widget_id, url}, state) do
    widget = Map.get(state.widgets, widget_id)

    if widget do
      :wxHtmlWindow.loadPage(widget, url)
    end

    state
  end
end
