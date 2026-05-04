defmodule LicenseCore do
  @moduledoc """
  Core license verification for MinuteModem.

  A valid installation requires TWO things:
    1. A signed license key (proves you paid)
    2. A signed activation assertion (proves this machine is authorized)

  ## Online activation

      LicenseCore.activate("MM-abc123...")
      # Verifies key → phones home → gets assertion → saves both

  ## Offline activation (from .mmlic file containing key + assertion)

      LicenseCore.activate_from_file("/mnt/usb/license.mmlic")

  ## Manual assertion installation

      LicenseCore.install_assertion("MMA-xyz789...")
  """

  alias LicenseCore.{License, Key, Assertion, Store, MachineId, ActivationReporter}

  @enabled Application.compile_env(:license_core, :enabled, true)

  @doc """
  Returns whether license checking is enabled in this build.
  """
  def enabled?, do: @enabled

  @doc """
  Check if a valid license AND assertion exist on disk.
  """
  def check do
    if enabled?() do
      with {:ok, key_string} <- load_or(:key, :unlicensed),
           {:ok, license} <- verify_key(key_string),
           :ok <- check_key_expiry(license),
           {:ok, assertion_string} <- load_or(:assertion, :no_assertion),
           {:ok, assertion} <- verify_assertion(assertion_string),
           :ok <- check_assertion_validity(assertion, key_string) do
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Online activation — verify key, phone home for assertion, save both.
  Returns {:ok, license} if the server grants an assertion.
  Returns {:error, reason} on failure.
  """
  def activate(key_string) when is_binary(key_string) do
    with {:ok, %License{} = license} <- Key.verify(key_string),
         false <- License.expired?(license),
         :ok <- Store.save(key_string) do
      # Phone home to get a signed assertion
      case ActivationReporter.request_assertion(key_string) do
        {:ok, assertion_string} ->
          # Verify the assertion we got back
          case Assertion.verify(assertion_string) do
            {:ok, _assertion} ->
              Store.save_assertion(assertion_string)
              {:ok, license}

            {:error, reason} ->
              Store.delete()
              {:error, {:bad_assertion, reason}}
          end

        {:error, :not_configured} ->
          # No activation URL configured — offline-only mode
          # Key is saved, but no assertion yet
          {:ok, license, :needs_assertion}

        {:error, :denied} ->
          Store.delete()
          {:error, :activation_denied}

        {:error, reason} ->
          # Network failure — key is saved but no assertion
          {:ok, license, {:assertion_failed, reason}}
      end
    else
      true -> {:error, :expired}
      {:error, _} = err -> err
    end
  end

  @doc """
  Activate from a .mmlic file (contains key + assertion).
  """
  def activate_from_file(path) when is_binary(path) do
    path =
      if String.ends_with?(path, ".mmlic"),
        do: path,
        else: path <> ".mmlic"

    case Store.read_mmlic(path) do
      {:ok, key_string, assertion_string} ->
        with {:ok, %License{} = license} <- Key.verify(key_string),
             false <- License.expired?(license),
             :ok <- Store.save(key_string) do
          if assertion_string do
            case Assertion.verify(assertion_string) do
              {:ok, _assertion} ->
                Store.save_assertion(assertion_string)
                {:ok, license}

              {:error, reason} ->
                Store.delete()
                {:error, {:bad_assertion, reason}}
            end
          else
            # Legacy .mmlic with no assertion
            {:ok, license, :needs_assertion}
          end
        else
          true -> {:error, :expired}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Install an assertion for an already-saved license key.
  Used when the assertion is obtained separately (e.g. from mmlicense tool).
  """
  def install_assertion(assertion_string) when is_binary(assertion_string) do
    with {:ok, key_string} <- Store.load(),
         {:ok, assertion} <- Assertion.verify(assertion_string),
         true <- Assertion.matches_key?(assertion, key_string) do
      Store.save_assertion(assertion_string)
      {:ok, assertion}
    else
      :error -> {:error, :no_license_key}
      false -> {:error, :assertion_key_mismatch}
      {:error, _} = err -> err
    end
  end

  @doc """
  Export the current license + assertion to a .mmlic file.
  """
  def export_to_file(path) when is_binary(path) do
    path =
      if String.ends_with?(path, ".mmlic"),
        do: path,
        else: path <> ".mmlic"

    with {:ok, key_string} <- Store.load(),
         {:ok, assertion_string} <- Store.load_assertion() do
      Store.write_mmlic(path, key_string, assertion_string)
    else
      :error -> {:error, :no_license}
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
  Returns detailed status of the current installation.
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
                %{status: :expired, license: license,
                  message: "License expired #{Date.diff(Date.utc_today(), license.expires)} days ago"}
              else
                # Check assertion
                case check_assertion_status(key_string) do
                  :ok ->
                    days_left = Date.diff(license.expires, Date.utc_today())
                    %{status: :active, license: license,
                      message: "Licensed to #{license.email}", days_remaining: days_left}

                  :no_assertion ->
                    %{status: :needs_assertion, license: license,
                      message: "License valid but no activation assertion"}

                  {:invalid, reason} ->
                    %{status: :invalid_assertion, license: license,
                      message: "Assertion invalid: #{inspect(reason)}"}
                end
              end

            {:error, reason} ->
              %{status: :invalid, message: "License file invalid: #{inspect(reason)}"}
          end

        :error ->
          %{status: :unlicensed, message: "No license found"}
      end
    end
  end

  @doc """
  Remove all stored license data.
  """
  def deactivate do
    Store.delete()
  end

  # ---------------------------------------------------------------
  # Internal checks
  # ---------------------------------------------------------------

  defp load_or(:key, fallback) do
    case Store.load() do
      {:ok, _} = ok -> ok
      :error -> fallback
    end
  end

  defp load_or(:assertion, fallback) do
    case Store.load_assertion() do
      {:ok, _} = ok -> ok
      :error -> fallback
    end
  end

  defp verify_key(key_string) do
    case Key.verify(key_string) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp check_key_expiry(license) do
    if License.expired?(license), do: {:expired, license}, else: :ok
  end

  defp verify_assertion(assertion_string) do
    Assertion.verify(assertion_string)
  end

  defp check_assertion_validity(assertion, key_string) do
    cond do
      Assertion.expired?(assertion) ->
        {:error, :assertion_expired}

      not Assertion.matches_key?(assertion, key_string) ->
        {:error, :assertion_key_mismatch}

      not Assertion.matches_machine?(assertion, MachineId.fingerprint()) ->
        {:error, :assertion_machine_mismatch}

      true ->
        :ok
    end
  end

  defp check_assertion_status(key_string) do
    case Store.load_assertion() do
      {:ok, assertion_string} ->
        case Assertion.verify(assertion_string) do
          {:ok, assertion} ->
            case check_assertion_validity(assertion, key_string) do
              :ok -> :ok
              {:error, reason} -> {:invalid, reason}
            end

          {:error, reason} ->
            {:invalid, reason}
        end

      :error ->
        :no_assertion
    end
  end
end
