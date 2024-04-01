defmodule WxMVU.Renderer.Intents.Widgets.Grid do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :grid, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for grid #{inspect(widget_id)}")
        state
      else
        rows = Keyword.get(opts, :rows, 10)
        cols = Keyword.get(opts, :cols, 5)

        widget = :wxGrid.new(parent, wxID_ANY())
        :wxGrid.createGrid(widget, rows, cols)

        # Set column labels if provided
        if col_labels = Keyword.get(opts, :col_labels) do
          col_labels
          |> Enum.with_index()
          |> Enum.each(fn {label, idx} ->
            :wxGrid.setColLabelValue(widget, idx, to_string(label))
          end)
        end

        # Set row labels if provided
        if row_labels = Keyword.get(opts, :row_labels) do
          row_labels
          |> Enum.with_index()
          |> Enum.each(fn {label, idx} ->
            :wxGrid.setRowLabelValue(widget, idx, to_string(label))
          end)
        end

        # Hide row labels if requested
        if Keyword.get(opts, :hide_row_labels, false) do
          :wxGrid.setRowLabelSize(widget, 0)
        end

        # Enable editing
        if Keyword.get(opts, :readonly, false) do
          :wxGrid.enableEditing(widget, false)
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

        :wxEvtHandler.connect(widget, :grid_cell_left_click)
        :wxEvtHandler.connect(widget, :grid_cell_changed)
        :wxEvtHandler.connect(widget, :grid_select_cell)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  # Set cell value
  def apply({:grid_set_cell, grid_id, row, col, value}, state) do
    grid = Map.get(state.widgets, grid_id)

    if grid do
      :wxGrid.setCellValue(grid, row, col, to_string(value))
    end

    state
  end

  # Set entire row
  def apply({:grid_set_row, grid_id, row, values}, state) do
    grid = Map.get(state.widgets, grid_id)

    if grid do
      values
      |> Enum.with_index()
      |> Enum.each(fn {value, col} ->
        :wxGrid.setCellValue(grid, row, col, to_string(value))
      end)
    end

    state
  end

  # Clear grid
  def apply({:grid_clear, grid_id}, state) do
    grid = Map.get(state.widgets, grid_id)

    if grid do
      :wxGrid.clearGrid(grid)
    end

    state
  end

  # Append row
  def apply({:grid_append_row, grid_id, values}, state) do
    grid = Map.get(state.widgets, grid_id)

    if grid do
      :wxGrid.appendRows(grid, numRows: 1)
      row = :wxGrid.getNumberRows(grid) - 1

      values
      |> Enum.with_index()
      |> Enum.each(fn {value, col} ->
        :wxGrid.setCellValue(grid, row, col, to_string(value))
      end)
    end

    state
  end
end
