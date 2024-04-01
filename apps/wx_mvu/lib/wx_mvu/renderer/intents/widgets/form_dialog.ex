defmodule WxMVU.Renderer.Intents.Widgets.FormDialog do
  @moduledoc """
  Generic form dialog that collects field values and returns them.

  Usage:
    {:show_dialog, :my_dialog, :form, :main, [
      title: "Edit Thing",
      fields: [
        {:name, :text, label: "Name", value: "default"},
        {:type, :choice, label: "Type", choices: ["a", "b"], selected: 0},
        {:count, :spin, label: "Count", min: 0, max: 100, value: 10}
      ]
    ]}

  Returns {:dialog_result, dialog_id, {:ok, %{name: "...", type: "...", count: 10}}}
  or {:dialog_result, dialog_id, :cancel}
  """

  use WxEx
  require Logger

  def apply({:show_dialog, dialog_id, :form, parent_id, opts}, state) do
    parent =
      Map.get(state.windows, parent_id) ||
        Map.get(state.panels, parent_id)

    if is_nil(parent) do
      Logger.debug("Renderer: parent not ready for form_dialog #{inspect(dialog_id)}")
      state
    else
      title = Keyword.get(opts, :title, "Form")
      fields = Keyword.get(opts, :fields, [])

      result = show_form_dialog(parent, title, fields)

      # Send result back as event
      send(self(), {:dialog_result, dialog_id, result})

      state
    end
  end

  defp show_form_dialog(parent, title, fields) do
    dialog = :wxDialog.new(parent, -1, title,
      style: Bitwise.bor(wxDEFAULT_DIALOG_STYLE(), wxRESIZE_BORDER()))

    panel = :wxPanel.new(dialog)
    main_sizer = :wxBoxSizer.new(wxVERTICAL())
    form_sizer = :wxFlexGridSizer.new(2, 5, 5)
    :wxFlexGridSizer.addGrowableCol(form_sizer, 1)

    # Build form fields and collect widget refs
    widgets =
      Enum.map(fields, fn {field_id, field_type, field_opts} ->
        label_text = Keyword.get(field_opts, :label, to_string(field_id))
        label = :wxStaticText.new(panel, -1, label_text <> ":")
        :wxSizer.add(form_sizer, label, flag: wxALIGN_CENTER_VERTICAL())

        widget = create_field_widget(panel, field_type, field_opts)
        :wxSizer.add(form_sizer, widget, flag: Bitwise.bor(wxEXPAND(), wxALIGN_CENTER_VERTICAL()))

        {field_id, field_type, widget}
      end)

    :wxSizer.add(main_sizer, form_sizer, proportion: 1,
      flag: Bitwise.bor(wxEXPAND(), wxALL()), border: 10)

    # Button sizer
    button_sizer = :wxBoxSizer.new(wxHORIZONTAL())
    :wxSizer.addStretchSpacer(button_sizer)
    ok_btn = :wxButton.new(panel, wxID_OK(), label: "Save")
    cancel_btn = :wxButton.new(panel, wxID_CANCEL(), label: "Cancel")
    :wxSizer.add(button_sizer, ok_btn, flag: wxRIGHT(), border: 5)
    :wxSizer.add(button_sizer, cancel_btn)

    :wxSizer.add(main_sizer, button_sizer, flag: Bitwise.bor(wxEXPAND(), wxALL()), border: 10)

    :wxPanel.setSizer(panel, main_sizer)

    # Dialog sizer
    dialog_sizer = :wxBoxSizer.new(wxVERTICAL())
    :wxSizer.add(dialog_sizer, panel, proportion: 1, flag: wxEXPAND())
    :wxDialog.setSizer(dialog, dialog_sizer)
    :wxDialog.fit(dialog)
    :wxDialog.centre(dialog)

    # Show modal and collect results
    modal_result = :wxDialog.showModal(dialog)
    ok_id = wxID_OK()

    result =
      if modal_result == ok_id do
        values = collect_values(widgets)
        {:ok, values}
      else
        :cancel
      end

    :wxDialog.destroy(dialog)
    result
  end

  defp create_field_widget(panel, :text, opts) do
    value = Keyword.get(opts, :value, "")
    :wxTextCtrl.new(panel, -1, value: value)
  end

  defp create_field_widget(panel, :choice, opts) do
    choices = Keyword.get(opts, :choices, [])
    selected = Keyword.get(opts, :selected, 0)
    widget = :wxChoice.new(panel, -1, choices: choices)
    if selected >= 0, do: :wxChoice.setSelection(widget, selected)
    widget
  end

  defp create_field_widget(panel, :spin, opts) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 100)
    value = Keyword.get(opts, :value, min)
    widget = :wxSpinCtrl.new(panel, min: min, max: max, initial: value)
    widget
  end

  defp create_field_widget(panel, :checkbox, opts) do
    label = Keyword.get(opts, :label, "")
    checked = Keyword.get(opts, :checked, false)
    widget = :wxCheckBox.new(panel, -1, label)
    :wxCheckBox.setValue(widget, checked)
    widget
  end

  defp collect_values(widgets) do
    widgets
    |> Enum.map(fn {field_id, field_type, widget} ->
      {field_id, get_value(field_type, widget)}
    end)
    |> Map.new()
  end

  defp get_value(:text, widget) do
    :wxTextCtrl.getValue(widget) |> to_string()
  end

  defp get_value(:choice, widget) do
    idx = :wxChoice.getSelection(widget)
    if idx >= 0 do
      :wxChoice.getString(widget, idx) |> to_string()
    else
      nil
    end
  end

  defp get_value(:spin, widget) do
    :wxSpinCtrl.getValue(widget)
  end

  defp get_value(:checkbox, widget) do
    :wxCheckBox.getValue(widget)
  end
end
