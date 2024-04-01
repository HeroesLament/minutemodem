defmodule WxMVU.Renderer.Intents.Widgets.SplitterWindow do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :splitter, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent =
        Map.get(state.windows, parent_id) ||
          Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for splitter #{inspect(widget_id)}")
        state
      else
        style = splitter_style(opts)

        widget = :wxSplitterWindow.new(parent, id: wxID_ANY(), style: style)

        # Set minimum pane size
        min_size = Keyword.get(opts, :min_pane_size, 100)
        :wxSplitterWindow.setMinimumPaneSize(widget, min_size)

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 1,
          flag: wxEXPAND()
        )

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  # Split horizontally (left/right panes)
  def apply({:split_vertical, splitter_id, left_panel_id, right_panel_id, opts}, state) do
    splitter = Map.get(state.widgets, splitter_id)
    left = Map.get(state.panels, left_panel_id)
    right = Map.get(state.panels, right_panel_id)

    if splitter && left && right do
      sash_position = Keyword.get(opts, :sash_position, 0)
      :wxSplitterWindow.splitVertically(splitter, left, right, sashPosition: sash_position)
    end

    state
  end

  # Split vertically (top/bottom panes)
  def apply({:split_horizontal, splitter_id, top_panel_id, bottom_panel_id, opts}, state) do
    splitter = Map.get(state.widgets, splitter_id)
    top = Map.get(state.panels, top_panel_id)
    bottom = Map.get(state.panels, bottom_panel_id)

    if splitter && top && bottom do
      sash_position = Keyword.get(opts, :sash_position, 0)
      :wxSplitterWindow.splitHorizontally(splitter, top, bottom, sashPosition: sash_position)
    end

    state
  end

  defp splitter_style(opts) do
    base = wxSP_3D()

    base = if Keyword.get(opts, :live_update, true), do: Bitwise.bor(base, wxSP_LIVE_UPDATE()), else: base
    base = if Keyword.get(opts, :no_border, false), do: wxSP_NOBORDER(), else: base

    base
  end
end
