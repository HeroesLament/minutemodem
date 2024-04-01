defmodule WxMVU.Renderer.Intents.Widgets.FileDialog do
  use WxEx
  require Logger

  def apply({:show_dialog, dialog_id, :file_open, parent_id, opts}, state) do
    parent =
      Map.get(state.windows, parent_id) ||
        Map.get(state.panels, parent_id)

    if is_nil(parent) do
      Logger.debug("Renderer: parent not ready for file_dialog #{inspect(dialog_id)}")
      state
    else
      message = Keyword.get(opts, :message, "Open file")
      wildcard = Keyword.get(opts, :wildcard, "*.*")
      default_dir = Keyword.get(opts, :default_dir, "")
      default_file = Keyword.get(opts, :default_file, "")
      style = wxFD_OPEN()

      style = if Keyword.get(opts, :multiple, false), do: Bitwise.bor(style, wxFD_MULTIPLE()), else: style
      style = if Keyword.get(opts, :must_exist, true), do: Bitwise.bor(style, wxFD_FILE_MUST_EXIST()), else: style

      dialog =
        :wxFileDialog.new(
          parent,
          message: message,
          defaultDir: default_dir,
          defaultFile: default_file,
          wildCard: wildcard,
          style: style
        )

      modal_result = :wxFileDialog.showModal(dialog)
      ok_id = wxID_OK()

      result =
        if modal_result == ok_id do
          if Keyword.get(opts, :multiple, false) do
            {:ok, :wxFileDialog.getPaths(dialog)}
          else
            {:ok, :wxFileDialog.getPath(dialog)}
          end
        else
          :cancel
        end

      :wxFileDialog.destroy(dialog)

      send(self(), {:dialog_result, dialog_id, result})

      state
    end
  end

  def apply({:show_dialog, dialog_id, :file_save, parent_id, opts}, state) do
    parent =
      Map.get(state.windows, parent_id) ||
        Map.get(state.panels, parent_id)

    if is_nil(parent) do
      Logger.debug("Renderer: parent not ready for file_dialog #{inspect(dialog_id)}")
      state
    else
      message = Keyword.get(opts, :message, "Save file")
      wildcard = Keyword.get(opts, :wildcard, "*.*")
      default_dir = Keyword.get(opts, :default_dir, "")
      default_file = Keyword.get(opts, :default_file, "")
      style = wxFD_SAVE()

      style = if Keyword.get(opts, :overwrite_prompt, true), do: Bitwise.bor(style, wxFD_OVERWRITE_PROMPT()), else: style

      dialog =
        :wxFileDialog.new(
          parent,
          message: message,
          defaultDir: default_dir,
          defaultFile: default_file,
          wildCard: wildcard,
          style: style
        )

      modal_result = :wxFileDialog.showModal(dialog)
      ok_id = wxID_OK()

      result =
        if modal_result == ok_id do
          {:ok, :wxFileDialog.getPath(dialog)}
        else
          :cancel
        end

      :wxFileDialog.destroy(dialog)

      send(self(), {:dialog_result, dialog_id, result})

      state
    end
  end

  def apply({:show_dialog, dialog_id, :dir, parent_id, opts}, state) do
    parent =
      Map.get(state.windows, parent_id) ||
        Map.get(state.panels, parent_id)

    if is_nil(parent) do
      Logger.debug("Renderer: parent not ready for dir_dialog #{inspect(dialog_id)}")
      state
    else
      message = Keyword.get(opts, :message, "Select directory")
      default_path = Keyword.get(opts, :default_path, "")

      dialog =
        :wxDirDialog.new(
          parent,
          message: message,
          defaultPath: default_path
        )

      modal_result = :wxDirDialog.showModal(dialog)
      ok_id = wxID_OK()

      result =
        if modal_result == ok_id do
          {:ok, :wxDirDialog.getPath(dialog)}
        else
          :cancel
        end

      :wxDirDialog.destroy(dialog)

      send(self(), {:dialog_result, dialog_id, result})

      state
    end
  end
end
