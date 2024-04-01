defmodule WxMVU.Renderer.Intents.Widgets.FilePicker do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :file_picker, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for file_picker #{inspect(widget_id)}")
        state
      else
        message = Keyword.get(opts, :message, "Select a file")
        wildcard = Keyword.get(opts, :wildcard, "*.*")
        path = Keyword.get(opts, :path, "")
        style = file_picker_style(opts)

        widget =
          :wxFilePickerCtrl.new(
            parent,
            wxID_ANY(),
            path: path,
            message: message,
            wildcard: wildcard,
            style: style
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_filepicker_changed)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp file_picker_style(opts) do
    base =
      if Keyword.get(opts, :save, false) do
        wxFLP_SAVE()
      else
        wxFLP_OPEN()
      end

    base = if Keyword.get(opts, :must_exist, true), do: Bitwise.bor(base, wxFLP_FILE_MUST_EXIST()), else: base
    base = if Keyword.get(opts, :overwrite_prompt, false), do: Bitwise.bor(base, wxFLP_OVERWRITE_PROMPT()), else: base
    base = if Keyword.get(opts, :use_textctrl, true), do: Bitwise.bor(base, wxFLP_USE_TEXTCTRL()), else: base
    base = if Keyword.get(opts, :small, false), do: Bitwise.bor(base, wxFLP_SMALL()), else: base

    base
  end
end
