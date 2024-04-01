defmodule WxMVU.Renderer.Intents.Widgets.TreeCtrl do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :tree_ctrl, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for tree_ctrl #{inspect(widget_id)}")
        state
      else
        style = tree_style(opts)

        widget =
          :wxTreeCtrl.new(
            parent,
            id: wxID_ANY(),
            style: style
          )

        # Initialize tree_roots map if needed
        state =
          if Map.has_key?(state, :tree_roots) do
            state
          else
            Map.put(state, :tree_roots, %{})
          end

        # Add root if provided
        state =
          if root_label = Keyword.get(opts, :root) do
            root = :wxTreeCtrl.addRoot(widget, root_label)
            put_in(state, [:tree_roots, widget_id], root)
          else
            state
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

        :wxEvtHandler.connect(widget, :command_tree_sel_changed)
        :wxEvtHandler.connect(widget, :command_tree_item_activated)
        :wxEvtHandler.connect(widget, :command_tree_item_expanded)
        :wxEvtHandler.connect(widget, :command_tree_item_collapsed)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  def apply({:tree_add_item, tree_id, item_id, parent_item, opts}, state) do
    tree = Map.get(state.widgets, tree_id)

    if tree do
      label = Keyword.get(opts, :label, "")

      parent_ref =
        case parent_item do
          :root -> get_in(state, [:tree_roots, tree_id])
          ref -> ref
        end

      if parent_ref do
        item = :wxTreeCtrl.appendItem(tree, parent_ref, label)

        tree_items = Map.get(state, :tree_items, %{})
        tree_items = Map.put(tree_items, {tree_id, item_id}, item)

        Map.put(state, :tree_items, tree_items)
      else
        state
      end
    else
      state
    end
  end

  def apply({:tree_expand, tree_id, item_id}, state) do
    tree = Map.get(state.widgets, tree_id)
    item = get_in(state, [:tree_items, {tree_id, item_id}])

    if tree && item do
      :wxTreeCtrl.expand(tree, item)
    end

    state
  end

  def apply({:tree_collapse, tree_id, item_id}, state) do
    tree = Map.get(state.widgets, tree_id)
    item = get_in(state, [:tree_items, {tree_id, item_id}])

    if tree && item do
      :wxTreeCtrl.collapse(tree, item)
    end

    state
  end

  defp tree_style(opts) do
    base = wxTR_DEFAULT_STYLE()

    base = if Keyword.get(opts, :hide_root, false), do: Bitwise.bor(base, wxTR_HIDE_ROOT()), else: base
    base = if Keyword.get(opts, :multiple, false), do: Bitwise.bor(base, wxTR_MULTIPLE()), else: base
    base = if Keyword.get(opts, :edit_labels, false), do: Bitwise.bor(base, wxTR_EDIT_LABELS()), else: base
    base = if Keyword.get(opts, :no_lines, false), do: Bitwise.bor(base, wxTR_NO_LINES()), else: base

    base
  end
end
