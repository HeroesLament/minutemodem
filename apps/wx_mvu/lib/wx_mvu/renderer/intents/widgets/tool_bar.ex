defmodule WxMVU.Renderer.Intents.Widgets.ToolBar do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :tool_bar, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      window = Map.get(state.windows, parent_id)

      if is_nil(window) do
        Logger.debug("Renderer: window not ready for tool_bar #{inspect(widget_id)}")
        state
      else
        style = toolbar_style(opts)

        widget = :wxFrame.createToolBar(window, style: style)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  def apply({:add_tool, toolbar_id, tool_id, opts}, state) do
    toolbar = Map.get(state.widgets, toolbar_id)

    if toolbar do
      label = Keyword.get(opts, :label, "")
      short_help = Keyword.get(opts, :help, "")
      kind = tool_kind(Keyword.get(opts, :kind, :normal))

      bmp = :wxArtProvider.getBitmap("wxART_NORMAL_FILE", size: {16, 16})

      tool_wx_id = :wx_misc.newId()
      :wxToolBar.addTool(toolbar, tool_wx_id, label, bmp, shortHelp: short_help, kind: kind)

      :wxEvtHandler.connect(toolbar, :command_tool_clicked, id: tool_wx_id)

      widget_ids = Map.put(state.widget_ids, tool_wx_id, tool_id)

      :wxToolBar.realize(toolbar)

      %{state | widget_ids: widget_ids}
    else
      state
    end
  end

  def apply({:add_tool_separator, toolbar_id}, state) do
    toolbar = Map.get(state.widgets, toolbar_id)

    if toolbar do
      :wxToolBar.addSeparator(toolbar)
      :wxToolBar.realize(toolbar)
    end

    state
  end

  defp toolbar_style(opts) do
    base = wxTB_HORIZONTAL()

    base = if Keyword.get(opts, :text, false), do: Bitwise.bor(base, wxTB_TEXT()), else: base
    base = if Keyword.get(opts, :no_icons, false), do: Bitwise.bor(base, wxTB_NOICONS()), else: base
    base = if Keyword.get(opts, :flat, true), do: Bitwise.bor(base, wxTB_FLAT()), else: base

    base
  end

  defp tool_kind(:normal), do: wxITEM_NORMAL()
  defp tool_kind(:check), do: wxITEM_CHECK()
  defp tool_kind(:radio), do: wxITEM_RADIO()
  defp tool_kind(_), do: wxITEM_NORMAL()
end
