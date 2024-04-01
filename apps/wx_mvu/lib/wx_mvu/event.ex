defmodule WxMVU.Event do
  @moduledoc """
  Normalized UI → State events emitted by the Renderer.
  """

  @type widget_id :: term()
  @type event_type :: atom()
  @type payload :: term()

  @type t ::
          {:ui_event, widget_id(), event_type(), payload()}
          | {:ui_event, widget_id(), event_type()}

  def click(widget_id) do
    {:ui_event, widget_id, :click}
  end

  def change(widget_id, value) do
    {:ui_event, widget_id, :change, value}
  end

  def select(widget_id, index) do
    {:ui_event, widget_id, :select, index}
  end

  def toggle(widget_id, value) do
    {:ui_event, widget_id, :toggle, value}
  end

  def raw(widget_id, type, payload \\ nil) do
    {:ui_event, widget_id, type, payload}
  end

  ## ------------------------------------------------------------------
  ## wx → Event translation
  ## ------------------------------------------------------------------

  @spec from_wx(widget_id :: term(), wx_event :: term()) :: t()

  # Button click
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_button_clicked, _, _, _}}) do
    click(widget_id)
  end

  # Toggle button
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_togglebutton_clicked, _, value, _}}) do
    toggle(widget_id, value == 1)
  end

  # Checkbox
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_checkbox_clicked, _, value, _}}) do
    toggle(widget_id, value == 1)
  end

  # Choice selection - index is 4th element
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_choice_selected, _, index, _}}) do
    change(widget_id, index)
  end

  # Combo box selection
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_combobox_selected, _, index, _}}) do
    change(widget_id, index)
  end

  # Text updated
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_text_updated, value, _, _}}) do
    change(widget_id, to_string(value))
  end

  # Text enter
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_text_enter, value, _, _}}) do
    raw(widget_id, :enter, to_string(value))
  end

  # List box selection
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_listbox_selected, _, index, _}}) do
    change(widget_id, index)
  end

  # List box double click
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_listbox_doubleclicked, _, index, _}}) do
    raw(widget_id, :double_click, index)
  end

  # Radio box
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_radiobox_selected, _, index, _}}) do
    change(widget_id, index)
  end

  # Slider
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_slider_updated, _, value, _}}) do
    change(widget_id, value)
  end

  # Spin control
  def from_wx(widget_id, {:wx, _, _, {:wxSpin, :command_spinctrl_updated, _, value, _}}) do
    change(widget_id, value)
  end

  # Menu selected
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_menu_selected, _, _, _}}) do
    click(widget_id)
  end

  # Tool clicked
  def from_wx(widget_id, {:wx, _, _, {:wxCommand, :command_tool_clicked, _, _, _}}) do
    click(widget_id)
  end

  # File picker changed
  def from_wx(widget_id, {:wx, _, _, {:wxFileDirPicker, :command_filepicker_changed, path}}) do
    change(widget_id, to_string(path))
  end

  # Colour picker changed
  def from_wx(widget_id, {:wx, _, _, {:wxColourPicker, :command_colourpicker_changed, colour}}) do
    change(widget_id, colour)
  end

  # Date picker changed
  def from_wx(widget_id, {:wx, _, _, {:wxDate, :date_changed, date}}) do
    change(widget_id, date)
  end

  # Notebook page changed
  def from_wx(widget_id, {:wx, _, _, {:wxBookCtrl, :command_notebook_page_changed, new_page, _old_page}}) do
    raw(widget_id, :page_changed, new_page)
  end

  # Window close
  def from_wx(widget_id, {:wx, _, _, {:wxClose, :close_window}}) do
    raw(widget_id, :close_window)
  end

  # Fallback - log what we're missing
  def from_wx(widget_id, wx_event) do
    require Logger
    Logger.warning("Event.from_wx fallback - unhandled event: #{inspect(wx_event)}")
    raw(widget_id, :wx, wx_event)
  end
end
