defmodule LicenseCore.Store do
  @moduledoc """
  Platform-aware license file storage.

  Stores both the license key and activation assertion to disk.

  Storage locations:
    - macOS:   ~/Library/Application Support/MinuteModem/
    - Linux:   $XDG_DATA_HOME/minutemodem/
    - Windows: %APPDATA%/MinuteModem/

  Files:
    - license.key       — the signed license key string
    - license.assertion  — the signed activation assertion
  """

  @key_filename "license.key"
  @assertion_filename "license.assertion"
  @mmlic_separator "\n---\n"

  # ---------------------------------------------------------------
  # License key
  # ---------------------------------------------------------------

  @doc """
  Load the license key string from disk.
  """
  def load do
    read_file(key_path())
  end

  @doc """
  Save a license key string to disk.
  """
  def save(key_string) when is_binary(key_string) do
    write_file(key_path(), key_string)
  end

  @doc """
  Delete the stored license key.
  """
  def delete do
    delete_file(key_path())
    delete_file(assertion_path())
  end

  # ---------------------------------------------------------------
  # Assertion
  # ---------------------------------------------------------------

  @doc """
  Load the activation assertion from disk.
  """
  def load_assertion do
    read_file(assertion_path())
  end

  @doc """
  Save an activation assertion to disk.
  """
  def save_assertion(assertion_string) when is_binary(assertion_string) do
    write_file(assertion_path(), assertion_string)
  end

  @doc """
  Delete only the assertion (keeps the key).
  """
  def delete_assertion do
    delete_file(assertion_path())
  end

  # ---------------------------------------------------------------
  # .mmlic file (bundled key + assertion)
  # ---------------------------------------------------------------

  @doc """
  Write a .mmlic file containing both key and assertion.
  """
  def write_mmlic(path, key_string, assertion_string) do
    contents = key_string <> @mmlic_separator <> assertion_string
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, contents) do
      {:ok, path}
    end
  end

  @doc """
  Read a .mmlic file, returning {key_string, assertion_string}.
  Also supports legacy format (key only, no assertion).
  """
  def read_mmlic(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents = String.trim(contents)

        case String.split(contents, @mmlic_separator, parts: 2) do
          [key, assertion] ->
            {:ok, String.trim(key), String.trim(assertion)}

          [key_only] ->
            {:ok, String.trim(key_only), nil}
        end

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  # ---------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------

  def key_path, do: Path.join(data_dir(), @key_filename)
  def assertion_path, do: Path.join(data_dir(), @assertion_filename)
  def license_path, do: key_path()

  @doc """
  Returns the platform-appropriate data directory.
  Can be overridden with MM_DATA_DIR environment variable.
  """
  def data_dir do
    case System.get_env("MM_DATA_DIR") do
      nil -> default_data_dir()
      dir -> dir
    end
  end

  # ---------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        trimmed = String.trim(contents)
        if trimmed == "", do: :error, else: {:ok, trimmed}

      {:error, _} ->
        :error
    end
  end

  defp write_file(path, contents) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, contents) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp delete_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  defp default_data_dir do
    case :os.type() do
      {:win32, _} ->
        Path.join(System.get_env("APPDATA", "C:/Users/Default/AppData/Roaming"), "MinuteModem")

      {:unix, :darwin} ->
        Path.join(
          System.get_env("HOME", "/tmp"),
          "Library/Application Support/MinuteModem"
        )

      {:unix, _} ->
        xdg =
          System.get_env(
            "XDG_DATA_HOME",
            Path.join(System.get_env("HOME", "/tmp"), ".local/share")
          )

        Path.join(xdg, "minutemodem")
    end
  end
end
