defmodule WxMVU.Renderer.Intents.Panel do
  use WxEx
  require Logger

  def apply({:ensure_panel, panel_id, parent_id, opts}, state) do
    if Map.has_key?(state.panels, panel_id) do
      state
    else
      parent = resolve_parent(parent_id, state)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for panel #{inspect(panel_id)}")
        state
      else
        style = build_style(opts)
        panel = :wxPanel.new(parent, [{:style, style}])

        if bg = Keyword.get(opts, :background) do
          :wxPanel.setBackgroundColour(panel, bg)
        end

        sizer = :wxBoxSizer.new(wxVERTICAL())
        :wxPanel.setSizer(panel, sizer)

        state = maybe_add_to_notebook(panel_id, parent_id, panel, opts, state)

        %{
          state
          | panels: Map.put(state.panels, panel_id, panel),
            sizers: Map.put(state.sizers, panel_id, sizer)
        }
      end
    end
  end

  def apply({:update_panel, panel_id, opts}, state) do
    case Map.get(state.panels, panel_id) do
      nil ->
        Logger.debug("Renderer: cannot update non-existent panel #{inspect(panel_id)}")
        state

      panel ->
        if bg = Keyword.get(opts, :background) do
          :wxPanel.setBackgroundColour(panel, bg)
          :wxPanel.refresh(panel)
        end

        state
    end
  end

  def apply({:destroy_panel, panel_id}, state) do
    case Map.get(state.panels, panel_id) do
      nil ->
        state

      panel ->
        :wxPanel.destroy(panel)

        %{
          state
          | panels: Map.delete(state.panels, panel_id),
            sizers: Map.delete(state.sizers, panel_id)
        }
    end
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp build_style(opts) do
    base = 0

    case Keyword.get(opts, :border) do
      :simple -> Bitwise.bor(base, wxBORDER_SIMPLE())
      :raised -> Bitwise.bor(base, wxBORDER_RAISED())
      :sunken -> Bitwise.bor(base, wxBORDER_SUNKEN())
      :static -> Bitwise.bor(base, wxBORDER_STATIC())
      _ -> base
    end
  end

  defp resolve_parent(parent_id, state) do
    case parent_id do
      {:page, _page_id} ->
        Map.get(state.panels, parent_id)

      _ ->
        Map.get(state.windows, parent_id) ||
          Map.get(state.panels, parent_id) ||
          Map.get(state.notebooks, parent_id)
    end
  end

  defp maybe_add_to_notebook(panel_id, parent_id, panel, opts, state) do
    case Map.get(state.notebooks, parent_id) do
      nil ->
        add_to_sizer(panel_id, parent_id, panel, state)

      notebook ->
        label = Keyword.get(opts, :label, "")
        :wxNotebook.addPage(notebook, panel, label)
        state
    end
  end

  defp add_to_sizer(_panel_id, parent_id, panel, state) do
    case Map.get(state.sizers, parent_id) do
      nil ->
        state

      parent_sizer ->
        :wxSizer.add(
          parent_sizer,
          panel,
          proportion: 1,
          flag: wxEXPAND()
        )

        state
    end
  end
end
