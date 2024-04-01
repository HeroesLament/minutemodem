defmodule WxMVU.Renderer.Intents.Widgets.MessageDialog do
  use WxEx
  require Logger

  # Message dialogs are shown immediately, not persisted
  # So this is a :show_dialog intent, not :ensure_widget
  def apply({:show_dialog, dialog_id, :message, parent_id, opts}, state) do
    parent =
      Map.get(state.windows, parent_id) ||
        Map.get(state.panels, parent_id)

    if is_nil(parent) do
      Logger.debug("Renderer: parent not ready for message_dialog #{inspect(dialog_id)}")
      state
    else
      message = Keyword.get(opts, :message, "")
      caption = Keyword.get(opts, :caption, "Message")
      style = dialog_style(opts)

      dialog = :wxMessageDialog.new(parent, message, caption: caption, style: style)
      result = :wxMessageDialog.showModal(dialog)
      :wxMessageDialog.destroy(dialog)

      # Send result back as event
      result_atom = modal_result(result)

      # Dispatch result event to AppState
      send(self(), {:dialog_result, dialog_id, result_atom})

      state
    end
  end

  defp dialog_style(opts) do
    type = Keyword.get(opts, :type, :ok)
    icon = Keyword.get(opts, :icon, :info)

    base =
      case type do
        :ok -> wxOK()
        :ok_cancel -> Bitwise.bor(wxOK(), wxCANCEL())
        :yes_no -> Bitwise.bor(wxYES_NO(), wxNO_DEFAULT())
        :yes_no_cancel -> Bitwise.bor(wxYES_NO(), wxCANCEL())
        _ -> wxOK()
      end

    icon_flag =
      case icon do
        :info -> wxICON_INFORMATION()
        :warning -> wxICON_WARNING()
        :error -> wxICON_ERROR()
        :question -> wxICON_QUESTION()
        _ -> wxICON_INFORMATION()
      end

    Bitwise.bor(base, icon_flag)
  end

  defp modal_result(result) do
    cond do
      result == wxID_OK() -> :ok
      result == wxID_CANCEL() -> :cancel
      result == wxID_YES() -> :yes
      result == wxID_NO() -> :no
      true -> :unknown
    end
  end
end
