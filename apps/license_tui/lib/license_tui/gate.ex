defmodule LicenseTUI.Gate do
  @moduledoc """
  License interlock gate for application startup.

  Call `LicenseTUI.Gate.require_license!/0` at the top of your
  Application.start/2 to block startup until a valid license is present.

  If licensing is disabled in the build, this is a no-op.

  ## Behavior

  - Valid license on disk → proceeds silently
  - Expired license → prints warning, blocks, prompts for new key
  - No license → blocks, prompts for key
  - Invalid license → blocks, prompts for key

  In interactive mode (TTY attached), the user gets the Owl-based
  activation prompt. In non-interactive mode (systemd, Docker, etc.),
  it prints an error and halts.
  """

  require Logger

  @doc """
  Check license and block startup if unlicensed.
  Returns :ok or halts the VM.
  """
  def require_license! do
    if LicenseCore.enabled?() do
      case LicenseCore.check() do
        :ok ->
          log_license_info()
          :ok

        {:expired, license} ->
          handle_expired(license)

        :unlicensed ->
          handle_unlicensed()

        :no_assertion ->
          handle_no_assertion()

        {:error, :assertion_expired} ->
          handle_assertion_expired()

        {:error, :assertion_machine_mismatch} ->
          handle_assertion_machine_mismatch()

        {:error, reason} ->
          handle_invalid(reason)
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------
  # Handlers
  # ---------------------------------------------------------------

  defp handle_expired(license) do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n⚠  License expired", :yellow),
        " on #{Date.to_iso8601(license.expires)} for #{license.email}\n"
      ])

      case Owl.IO.select(["Enter a new license key", "Quit"],
             label: "Your license has expired."
           ) do
        "Enter a new license key" ->
          prompt_until_valid()

        "Quit" ->
          halt_unlicensed()
      end
    else
      Logger.error("License expired on #{license.expires} for #{license.email}")
      Logger.error("Activate with: #{release_name()} eval 'LicenseTUI.activate()'")
      halt_unlicensed()
    end
  end

  defp handle_unlicensed do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n⚠  No license found.\n", :yellow)
      ])

      case Owl.IO.select(["Enter a license key", "Activate from file (.mmlic)", "Quit"],
             label: "MinuteModem requires a license to run."
           ) do
        "Enter a license key" ->
          prompt_until_valid()

        "Activate from file (.mmlic)" ->
          prompt_file_activation()

        "Quit" ->
          halt_unlicensed()
      end
    else
      Logger.error("No valid license found.")
      Logger.error("Activate with: #{release_name()} eval 'LicenseTUI.activate()'")
      Logger.error("Or copy a .mmlic file to: #{LicenseCore.Store.license_path()}")
      halt_unlicensed()
    end
  end

  defp handle_invalid(reason) do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n✗  License file is invalid: ", :red),
        inspect(reason),
        "\n"
      ])

      case Owl.IO.select(["Enter a new license key", "Quit"],
             label: "Would you like to activate?"
           ) do
        "Enter a new license key" ->
          prompt_until_valid()

        "Quit" ->
          halt_unlicensed()
      end
    else
      Logger.error("License file invalid: #{inspect(reason)}")
      Logger.error("Activate with: #{release_name()} eval 'LicenseTUI.activate()'")
      halt_unlicensed()
    end
  end

  # ---------------------------------------------------------------
  # Assertion-specific handlers
  # ---------------------------------------------------------------

  defp handle_no_assertion do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n⚠  License key is valid but this machine is not activated.\n", :yellow)
      ])

      case Owl.IO.select(
             ["Activate online (phone home)", "Load assertion from file", "Quit"],
             label: "This machine needs an activation assertion."
           ) do
        "Activate online (phone home)" ->
          attempt_online_assertion()

        "Load assertion from file" ->
          prompt_assertion_file()

        "Quit" ->
          halt_unlicensed()
      end
    else
      Logger.error("License valid but no activation assertion for this machine.")
      Logger.error("Activate with: #{release_name()} eval 'LicenseTUI.activate()'")
      halt_unlicensed()
    end
  end

  defp handle_assertion_expired do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n⚠  Activation assertion has expired.\n", :yellow)
      ])

      case Owl.IO.select(
             ["Re-activate online", "Load new assertion from file", "Quit"],
             label: "Your activation assertion has expired."
           ) do
        "Re-activate online" -> attempt_online_assertion()
        "Load new assertion from file" -> prompt_assertion_file()
        "Quit" -> halt_unlicensed()
      end
    else
      Logger.error("Activation assertion expired. Re-activate or install a new .mmlic.")
      halt_unlicensed()
    end
  end

  defp handle_assertion_machine_mismatch do
    if interactive?() do
      Owl.IO.puts([
        Owl.Data.tag("\n✗  This activation assertion is for a different machine.\n", :red)
      ])

      case Owl.IO.select(
             ["Activate this machine online", "Load correct assertion", "Quit"],
             label: "The stored assertion doesn't match this machine."
           ) do
        "Activate this machine online" -> attempt_online_assertion()
        "Load correct assertion" -> prompt_assertion_file()
        "Quit" -> halt_unlicensed()
      end
    else
      Logger.error("Activation assertion is for a different machine.")
      halt_unlicensed()
    end
  end

  defp attempt_online_assertion do
    Owl.IO.puts(["  Contacting license server..."])

    case LicenseCore.Store.load() do
      {:ok, key_string} ->
        case LicenseCore.ActivationReporter.request_assertion(key_string) do
          {:ok, assertion_string} ->
            case LicenseCore.Assertion.verify(assertion_string) do
              {:ok, _} ->
                LicenseCore.Store.save_assertion(assertion_string)
                Owl.IO.puts([Owl.Data.tag("✓ ", :green), "Machine activated!\n"])
                :ok

              {:error, reason} ->
                Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Server returned invalid assertion: #{inspect(reason)}\n"])
                halt_unlicensed()
            end

          {:error, :seat_limit_exceeded} ->
            Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Seat limit exceeded. Contact your administrator.\n"])
            halt_unlicensed()

          {:error, :denied} ->
            Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Activation denied by server.\n"])
            halt_unlicensed()

          {:error, :not_configured} ->
            Owl.IO.puts([Owl.Data.tag("✗ ", :red), "No activation server configured.\n"])
            halt_unlicensed()

          {:error, reason} ->
            Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Activation failed: #{inspect(reason)}\n"])
            halt_unlicensed()
        end

      :error ->
        Owl.IO.puts([Owl.Data.tag("✗ ", :red), "No license key on disk.\n"])
        halt_unlicensed()
    end
  end

  defp prompt_assertion_file do
    path =
      Owl.IO.input(
        label: "Path to .mmlic or assertion file",
        cast: fn input ->
          trimmed = String.trim(input)
          if File.exists?(trimmed), do: {:ok, trimmed}, else: {:error, "File not found: #{trimmed}"}
        end
      )

    Owl.IO.puts("")

    if String.ends_with?(path, ".mmlic") do
      case LicenseCore.activate_from_file(path) do
        {:ok, license} ->
          Owl.IO.puts([Owl.Data.tag("✓ ", :green), "Activated for #{license.email}\n"])
          :ok

        {:ok, _license, :needs_assertion} ->
          Owl.IO.puts([Owl.Data.tag("✗ ", :red), "File has no assertion. Need a newer .mmlic.\n"])
          halt_unlicensed()

        {:error, reason} ->
          Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Failed: #{inspect(reason)}\n"])
          halt_unlicensed()
      end
    else
      case File.read(path) do
        {:ok, contents} ->
          case LicenseCore.install_assertion(String.trim(contents)) do
            {:ok, _} ->
              Owl.IO.puts([Owl.Data.tag("✓ ", :green), "Assertion installed!\n"])
              :ok

            {:error, reason} ->
              Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Failed: #{inspect(reason)}\n"])
              halt_unlicensed()
          end

        {:error, reason} ->
          Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Can't read file: #{inspect(reason)}\n"])
          halt_unlicensed()
      end
    end
  end

  # ---------------------------------------------------------------
  # Key entry prompts
  # ---------------------------------------------------------------

  defp prompt_until_valid do
    key =
      Owl.IO.input(
        label: "Paste your license key",
        cast: fn input ->
          trimmed = String.trim(input)

          if String.starts_with?(trimmed, "MM-") do
            {:ok, trimmed}
          else
            {:error, "Key must start with MM-"}
          end
        end
      )

    Owl.IO.puts("")

    case LicenseCore.activate(key) do
      {:ok, license} ->
        Owl.IO.puts([
          Owl.Data.tag("✓ ", :green),
          "Licensed to ",
          Owl.Data.tag(license.email, :cyan),
          " — expires ",
          Owl.Data.tag(Date.to_iso8601(license.expires), :yellow),
          "\n"
        ])

        :ok

      {:error, reason} ->
        msg =
          case reason do
            :expired -> "That key has expired."
            :invalid_signature -> "Invalid key. Check and try again."
            :invalid_format -> "Malformed key (expected MM-...)"
            other -> "Error: #{inspect(other)}"
          end

        Owl.IO.puts([Owl.Data.tag("✗ ", :red), msg, "\n"])

        case Owl.IO.select(["Try again", "Quit"], label: "What would you like to do?") do
          "Try again" -> prompt_until_valid()
          "Quit" -> halt_unlicensed()
        end
    end
  end

  defp prompt_file_activation do
    path =
      Owl.IO.input(
        label: "Path to .mmlic file",
        cast: fn input ->
          trimmed = String.trim(input)

          if File.exists?(trimmed) do
            {:ok, trimmed}
          else
            {:error, "File not found: #{trimmed}"}
          end
        end
      )

    Owl.IO.puts("")

    case LicenseCore.activate_from_file(path) do
      {:ok, license} ->
        Owl.IO.puts([
          Owl.Data.tag("✓ ", :green),
          "Licensed to ",
          Owl.Data.tag(license.email, :cyan),
          " — expires ",
          Owl.Data.tag(Date.to_iso8601(license.expires), :yellow),
          "\n"
        ])

        :ok

      {:error, reason} ->
        Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Failed: #{inspect(reason)}\n"])

        case Owl.IO.select(["Try again", "Enter key manually", "Quit"],
               label: "What would you like to do?"
             ) do
          "Try again" -> prompt_file_activation()
          "Enter key manually" -> prompt_until_valid()
          "Quit" -> halt_unlicensed()
        end
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp log_license_info do
    case LicenseCore.current_license() do
      {:ok, license} ->
        days = Date.diff(license.expires, Date.utc_today())

        if days <= 30 do
          Logger.warning("License expires in #{days} days (#{license.expires})")
        else
          Logger.info("Licensed to #{license.email} [#{license.tier}] expires #{license.expires}")
        end

      _ ->
        :ok
    end
  end

  defp interactive? do
    # Check if we have a TTY attached
    IO.ANSI.enabled?()
  end

  defp release_name do
    # Try to figure out the release name for helpful error messages
    System.get_env("RELEASE_NAME") || "minutemodem"
  end

  defp halt_unlicensed do
    Logger.error("MinuteModem cannot start without a valid license.")
    System.halt(1)
  end
end
