defmodule LicenseCore.Store do
  @moduledoc """
  Platform-aware license file storage.

  Stores the raw license key string to disk so it persists across restarts.

  Storage locations:
    - macOS:   ~/Library/Application Support/MinuteModem/license.key
    - Linux:   $XDG_DATA_HOME/minutemodem/license.key (or ~/.local/share/minutemodem/)
    - Windows: %APPDATA%/MinuteModem/license.key
  """

  @filename "license.key"

  @doc """
  Load the license key string from disk.
  """
  def load do
    path = license_path()

    case File.read(path) do
      {:ok, contents} ->
        key = String.trim(contents)
        if key == "", do: :error, else: {:ok, key}

      {:error, _} ->
        :error
    end
  end

  @doc """
  Save a license key string to disk.
  """
  def save(key_string) when is_binary(key_string) do
    path = license_path()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, key_string) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Delete the stored license.
  """
  def delete do
    path = license_path()

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  @doc """
  Returns the full path to the license file.
  """
  def license_path do
    Path.join(data_dir(), @filename)
  end

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
