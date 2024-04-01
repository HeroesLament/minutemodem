defmodule WxMVU.Renderer.Intents.Widgets do
  @moduledoc """
  Routes widget intents to specific handlers.
  """

  use WxEx
  require Logger

  alias WxMVU.Renderer.Intents.Widgets.{
    Notebook,
    StaticText,
    Choice,
    Button,
    TextCtrl,
    SpinCtrl,
    Slider,
    ToggleButton,
    RadioBox,
    Checkbox,
    ListBox,
    Gauge,
    StatusBar,
    MessageDialog,
    ComboBox,
    StaticBox,
    SplitterWindow,
    ToolBar,
    MenuBar,
    TreeCtrl,
    Grid,
    ScrolledWindow,
    FormDialog,
    FileDialog,
    DatePicker,
    ColourPicker,
    FilePicker,
    Calendar,
    HtmlWindow
  }

  ## ------------------------------------------------------------------
  ## Ensure widget (create)
  ## ------------------------------------------------------------------

  def apply({:ensure_widget, _, :notebook, _, _} = intent, state), do: Notebook.apply(intent, state)
  def apply({:ensure_widget, _, :static_text, _, _} = intent, state), do: StaticText.apply(intent, state)
  def apply({:ensure_widget, _, :choice, _, _} = intent, state), do: Choice.apply(intent, state)
  def apply({:ensure_widget, _, :button, _, _} = intent, state), do: Button.apply(intent, state)
  def apply({:ensure_widget, _, :text_ctrl, _, _} = intent, state), do: TextCtrl.apply(intent, state)
  def apply({:ensure_widget, _, :spin_ctrl, _, _} = intent, state), do: SpinCtrl.apply(intent, state)
  def apply({:ensure_widget, _, :spin_ctrl_double, _, _} = intent, state), do: SpinCtrl.apply(intent, state)
  def apply({:ensure_widget, _, :slider, _, _} = intent, state), do: Slider.apply(intent, state)
  def apply({:ensure_widget, _, :toggle_button, _, _} = intent, state), do: ToggleButton.apply(intent, state)
  def apply({:ensure_widget, _, :radio_box, _, _} = intent, state), do: RadioBox.apply(intent, state)
  def apply({:ensure_widget, _, :checkbox, _, _} = intent, state), do: Checkbox.apply(intent, state)
  def apply({:ensure_widget, _, :list_box, _, _} = intent, state), do: ListBox.apply(intent, state)
  def apply({:ensure_widget, _, :gauge, _, _} = intent, state), do: Gauge.apply(intent, state)
  def apply({:ensure_widget, _, :status_bar, _, _} = intent, state), do: StatusBar.apply(intent, state)
  def apply({:ensure_widget, _, :combo_box, _, _} = intent, state), do: ComboBox.apply(intent, state)
  def apply({:ensure_widget, _, :static_box, _, _} = intent, state), do: StaticBox.apply(intent, state)
  def apply({:ensure_widget, _, :splitter, _, _} = intent, state), do: SplitterWindow.apply(intent, state)
  def apply({:ensure_widget, _, :tool_bar, _, _} = intent, state), do: ToolBar.apply(intent, state)
  def apply({:ensure_widget, _, :menu_bar, _, _} = intent, state), do: MenuBar.apply(intent, state)
  def apply({:ensure_widget, _, :tree_ctrl, _, _} = intent, state), do: TreeCtrl.apply(intent, state)
  def apply({:ensure_widget, _, :grid, _, _} = intent, state), do: Grid.apply(intent, state)
  def apply({:ensure_widget, _, :scrolled_window, _, _} = intent, state), do: ScrolledWindow.apply(intent, state)
  def apply({:ensure_widget, _, :date_picker, _, _} = intent, state), do: DatePicker.apply(intent, state)
  def apply({:ensure_widget, _, :colour_picker, _, _} = intent, state), do: ColourPicker.apply(intent, state)
  def apply({:ensure_widget, _, :file_picker, _, _} = intent, state), do: FilePicker.apply(intent, state)
  def apply({:ensure_widget, _, :calendar, _, _} = intent, state), do: Calendar.apply(intent, state)
  def apply({:ensure_widget, _, :html_window, _, _} = intent, state), do: HtmlWindow.apply(intent, state)

  def apply({:ensure_widget, widget_id, type, _, _}, state) do
    Logger.warning("Renderer: unknown widget type #{inspect(type)} for #{inspect(widget_id)}")
    state
  end

  ## ------------------------------------------------------------------
  ## Update widget
  ## ------------------------------------------------------------------

  def apply({:update_widget, widget_id, type, opts}, state) do
    case Map.get(state.widgets, widget_id) do
      nil ->
        Logger.debug("Renderer: cannot update non-existent widget #{inspect(widget_id)}")
        state

      widget ->
        update_widget(widget, type, opts)
        state
    end
  end

  ## ------------------------------------------------------------------
  ## Destroy widget
  ## ------------------------------------------------------------------

  def apply({:destroy_widget, widget_id, _type}, state) do
    widget = Map.get(state.widgets, widget_id)
    panel = Map.get(state.panels, widget_id)

    cond do
      widget ->
        :wxWindow.destroy(widget)

        %{
          state
          | widgets: Map.delete(state.widgets, widget_id),
            widget_ids: Map.delete(state.widget_ids, widget),
            sizers: Map.delete(state.sizers, widget_id)
        }

      panel ->
        # For static_box which registers in panels
        :wxWindow.destroy(panel)

        %{
          state
          | panels: Map.delete(state.panels, widget_id),
            sizers: Map.delete(state.sizers, widget_id)
        }

      true ->
        state
    end
  end

  ## ------------------------------------------------------------------
  ## Splitter operations
  ## ------------------------------------------------------------------

  def apply({:split_vertical, _, _, _, _} = intent, state), do: SplitterWindow.apply(intent, state)
  def apply({:split_horizontal, _, _, _, _} = intent, state), do: SplitterWindow.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Toolbar operations
  ## ------------------------------------------------------------------

  def apply({:add_tool, _, _, _} = intent, state), do: ToolBar.apply(intent, state)
  def apply({:add_tool_separator, _} = intent, state), do: ToolBar.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Menu operations
  ## ------------------------------------------------------------------

  def apply({:add_menu, _, _, _} = intent, state), do: MenuBar.apply(intent, state)
  def apply({:add_menu_item, _, _, _} = intent, state), do: MenuBar.apply(intent, state)
  def apply({:add_menu_separator, _} = intent, state), do: MenuBar.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Tree operations
  ## ------------------------------------------------------------------

  def apply({:tree_add_item, _, _, _, _} = intent, state), do: TreeCtrl.apply(intent, state)
  def apply({:tree_expand, _, _} = intent, state), do: TreeCtrl.apply(intent, state)
  def apply({:tree_collapse, _, _} = intent, state), do: TreeCtrl.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Grid operations
  ## ------------------------------------------------------------------

  def apply({:grid_set_cell, _, _, _, _} = intent, state), do: Grid.apply(intent, state)
  def apply({:grid_set_row, _, _, _} = intent, state), do: Grid.apply(intent, state)
  def apply({:grid_clear, _} = intent, state), do: Grid.apply(intent, state)
  def apply({:grid_append_row, _, _} = intent, state), do: Grid.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Scrolled window operations
  ## ------------------------------------------------------------------

  def apply({:scroll_set_virtual_size, _, _, _} = intent, state), do: ScrolledWindow.apply(intent, state)
  def apply({:scroll_to, _, _, _} = intent, state), do: ScrolledWindow.apply(intent, state)

  ## ------------------------------------------------------------------
  ## HTML window operations
  ## ------------------------------------------------------------------

  def apply({:html_set_page, _, _} = intent, state), do: HtmlWindow.apply(intent, state)
  def apply({:html_load_page, _, _} = intent, state), do: HtmlWindow.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Dialogs
  ## ------------------------------------------------------------------

  def apply({:show_dialog, _, :form, _, _} = intent, state), do: FormDialog.apply(intent, state)
  def apply({:show_dialog, _, :message, _, _} = intent, state), do: MessageDialog.apply(intent, state)
  def apply({:show_dialog, _, :file_open, _, _} = intent, state), do: FileDialog.apply(intent, state)
  def apply({:show_dialog, _, :file_save, _, _} = intent, state), do: FileDialog.apply(intent, state)
  def apply({:show_dialog, _, :dir, _, _} = intent, state), do: FileDialog.apply(intent, state)

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp update_widget(widget, :button, opts) do
    if label = Keyword.get(opts, :label) do
      :wxButton.setLabel(widget, label)
    end
  end

  defp update_widget(widget, :static_text, opts) do
    if label = Keyword.get(opts, :label) do
      :wxStaticText.setLabel(widget, label)
    end
  end

  defp update_widget(widget, :checkbox, opts) do
    if label = Keyword.get(opts, :label) do
      :wxCheckBox.setLabel(widget, label)
    end
  end

  defp update_widget(widget, :toggle_button, opts) do
    if label = Keyword.get(opts, :label) do
      :wxToggleButton.setLabel(widget, label)
    end
  end

defp update_widget(widget, :gauge, opts) do
    if range = Keyword.get(opts, :range) do
      :wxGauge.setRange(widget, range)
    end
  end

  defp update_widget(widget, :choice, opts) do
    if choices = Keyword.get(opts, :choices) do
      :wxChoice.clear(widget)
      Enum.each(choices, fn choice ->
        :wxChoice.append(widget, to_string(choice))
      end)
    end
  end

  defp update_widget(widget, :list_box, opts) do
    if items = Keyword.get(opts, :choices) do
      :wxListBox.clear(widget)
      Enum.each(items, fn item ->
        :wxListBox.append(widget, to_string(item))
      end)
    end
  end

  defp update_widget(_widget, _type, _opts), do: :ok
end
