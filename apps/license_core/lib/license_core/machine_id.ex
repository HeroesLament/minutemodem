defmodule LicenseCore.MachineId do
  @moduledoc """
  Platform-aware machine fingerprint generation.

  Produces a stable, hashed identifier for the current machine.
  Used for activation tracking — not enforcement.
  """

  @doc """
  Returns a hex-encoded SHA-256 hash of the machine's identity.
  """
  def fingerprint do
    raw = raw_id()
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc """
  Returns human-readable machine info for the activation record.
  """
  def machine_info do
    %{
      hostname: hostname(),
      os: os_string(),
      arch: to_string(:erlang.system_info(:system_architecture)),
      otp_release: to_string(:erlang.system_info(:otp_release))
    }
  end

  # ---------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------

  defp raw_id do
    # Combine platform-specific ID with hostname for a stable fingerprint
    platform_id() <> ":" <> hostname()
  end

  defp platform_id do
    case :os.type() do
      {:unix, :darwin} -> macos_id()
      {:unix, _} -> linux_id()
      {:win32, _} -> windows_id()
    end
  end

  defp macos_id do
    # IOPlatformUUID from IOKit — stable across OS reinstalls
    case System.cmd("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/"IOPlatformUUID"\s*=\s*"([^"]+)"/, output) do
          [_, uuid] -> uuid
          _ -> fallback_id()
        end

      _ ->
        fallback_id()
    end
  rescue
    _ -> fallback_id()
  end

  defp linux_id do
    # /etc/machine-id is standard on systemd systems
    case File.read("/etc/machine-id") do
      {:ok, id} -> String.trim(id)
      _ ->
        # Fallback to /var/lib/dbus/machine-id
        case File.read("/var/lib/dbus/machine-id") do
          {:ok, id} -> String.trim(id)
          _ -> fallback_id()
        end
    end
  end

  defp windows_id do
    case System.cmd("cmd", ["/c", "wmic", "csproduct", "get", "UUID", "/value"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Regex.run(~r/UUID=(.+)/, String.trim(output)) do
          [_, uuid] -> String.trim(uuid)
          _ -> fallback_id()
        end

      _ ->
        fallback_id()
    end
  rescue
    _ -> fallback_id()
  end

  defp fallback_id do
    # Last resort: hostname + OTP node
    "#{hostname()}:#{node()}"
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp os_string do
    {family, name} = :os.type()
    "#{family}:#{name}"
  end
end
