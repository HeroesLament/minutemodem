defmodule LicenseCore do
  @moduledoc """
  Core license verification for MinuteModem.

  License keys are Ed25519-signed payloads in the format:

      MM-<base64url payload>.<base64url signature>

  The payload is a pipe-delimited string:

      email|expiry_iso8601|tier

  ## Activation methods

      # From a key string (pasted by user)
      LicenseCore.activate("MM-abc123...")

      # From a .mmlic file (USB install, airgapped)
      LicenseCore.activate_from_file("/mnt/usb/license.mmlic")

      # Check existing license
      LicenseCore.check()

  ## Build-time toggle

  Set `config :license_core, :enabled, true` to require license checks.
  Defaults to `false` (open-source builds skip all checks).
  """

  alias LicenseCore.{License, Key, Store, ActivationReporter}

  @enabled Application.compile_env(:license_core, :enabled, false)
  @mmlic_extension ".mmlic"

  @doc """
  Returns whether license checking is enabled in this build.
  """
  def enabled?, do: @enabled

  @doc """
  Check if a valid license exists on disk.
  Returns `:ok` if licensing is disabled or a valid license is found.
  """
  def check do
    if enabled?() do
      case Store.load() do
        {:ok, key_string} ->
          case Key.verify(key_string) do
            {:ok, %License{} = license} ->
              if License.expired?(license), do: {:expired, license}, else: :ok

            {:error, _} = err ->
              err
          end

        :error ->
          :unlicensed
      end
    else
      :ok
    end
  end

  @doc """
  Verify a key string, store it to disk, and report activation.
  """
  def activate(key_string) when is_binary(key_string) do
    with {:ok, %License{} = license} <- Key.verify(key_string),
         false <- License.expired?(license),
         :ok <- Store.save(key_string) do
      # Best-effort phone-home — never blocks, never fails the activation
      ActivationReporter.report(key_string)
      {:ok, license}
    else
      true -> {:error, :expired}
      {:error, _} = err -> err
    end
  end

  @doc """
  Activate from a .mmlic file.
  Reads the key string from the file, then runs the normal activation flow.
  """
  def activate_from_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        key_string = String.trim(contents)

        if key_string == "" do
          {:error, :empty_file}
        else
          activate(key_string)
        end

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  @doc """
  Export the current license to a .mmlic file.
  Useful for transferring to an airgapped machine.
  """
  def export_to_file(path) when is_binary(path) do
    path =
      if String.ends_with?(path, @mmlic_extension),
        do: path,
        else: path <> @mmlic_extension

    case Store.load() do
      {:ok, key_string} ->
        dir = Path.dirname(path)

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(path, key_string) do
          {:ok, path}
        end

      :error ->
        {:error, :no_license}
    end
  end

  @doc """
  Verify a key string without storing.
  """
  def verify(key_string) do
    Key.verify(key_string)
  end

  @doc """
  Returns the current license if one exists and is valid.
  """
  def current_license do
    case Store.load() do
      {:ok, key_string} -> Key.verify(key_string)
      :error -> :unlicensed
    end
  end

  @doc """
  Returns detailed status of the current license.
  """
  def status do
    if not enabled?() do
      %{status: :open_source, message: "Licensing not enabled in this build"}
    else
      case Store.load() do
        {:ok, key_string} ->
          case Key.verify(key_string) do
            {:ok, %License{} = license} ->
              if License.expired?(license) do
                days_ago = Date.diff(Date.utc_today(), license.expires)

                %{
                  status: :expired,
                  license: license,
                  message: "License expired #{days_ago} days ago",
                  days_expired: days_ago
                }
              else
                days_left = Date.diff(license.expires, Date.utc_today())

                %{
                  status: :active,
                  license: license,
                  message: "Licensed to #{license.email}",
                  days_remaining: days_left
                }
              end

            {:error, reason} ->
              %{status: :invalid, message: "License file is invalid: #{inspect(reason)}"}
          end

        :error ->
          %{status: :unlicensed, message: "No license found"}
      end
    end
  end

  @doc """
  Remove the stored license from disk.
  """
  def deactivate do
    Store.delete()
  end
end
