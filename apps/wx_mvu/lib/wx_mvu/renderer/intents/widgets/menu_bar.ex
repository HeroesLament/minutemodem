defmodule WxMVU.Renderer.Intents.Widgets.MenuBar do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :menu_bar, parent_id, _opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      window = Map.get(state.windows, parent_id)

      if is_nil(window) do
        Logger.debug("Renderer: window not ready for menu_bar #{inspect(widget_id)}")
        state
      else
        widget = :wxMenuBar.new()
        :wxFrame.setMenuBar(window, widget)

        state = Map.put(state, :menu_frame, window)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  def apply({:add_menu, menu_bar_id, menu_id, opts}, state) do
    menu_bar = Map.get(state.widgets, menu_bar_id)

    if menu_bar do
      title = Keyword.get(opts, :title, "Menu")

      menu = :wxMenu.new()
      :wxMenuBar.append(menu_bar, menu, title)

      %{
        state
        | widgets: Map.put(state.widgets, menu_id, menu),
          widget_ids: Map.put(state.widget_ids, menu, menu_id)
      }
    else
      state
    end
  end

  def apply({:add_menu_item, menu_id, item_id, opts}, state) do
    menu = Map.get(state.widgets, menu_id)

    if menu do
      label = Keyword.get(opts, :label, "Item")
      help = Keyword.get(opts, :help, "")
      kind = Keyword.get(opts, :kind, :normal)

      item_wx_id = :wx_misc.newId()

      case kind do
        :check ->
          :wxMenu.appendCheckItem(menu, item_wx_id, label, help)

        :radio ->
          :wxMenu.appendRadioItem(menu, item_wx_id, label, help)

        _ ->
          :wxMenu.append(menu, item_wx_id, label, help)
      end

      if frame = Map.get(state, :menu_frame) do
        :wxEvtHandler.connect(frame, :command_menu_selected, id: item_wx_id)
      end

      widget_ids = Map.put(state.widget_ids, item_wx_id, item_id)

      %{state | widget_ids: widget_ids}
    else
      state
    end
  end

  def apply({:add_menu_separator, menu_id}, state) do
    menu = Map.get(state.widgets, menu_id)

    if menu do
      :wxMenu.appendSeparator(menu)
    end

    state
  end
end
