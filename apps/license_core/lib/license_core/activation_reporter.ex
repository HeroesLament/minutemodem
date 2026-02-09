defmodule LicenseCore.ActivationReporter do
  @moduledoc """
  Best-effort activation reporting.

  When a license is activated on an online machine, this module
  attempts to POST the activation to the license API server.
  If the server is unreachable, it silently succeeds — the license
  still works. The report is fire-and-forget.

  Configure the API URL:

      config :license_core, :activation_url, "https://license.minutemodem.com/api/activations"

  If not configured, reporting is silently skipped.
  """

  require Logger

  alias LicenseCore.MachineId

  @doc """
  Report an activation to the license server. Fire-and-forget.
  Spawns an async task so it never blocks the activation flow.
  """
  def report(key_string) do
    case activation_url() do
      nil ->
        Logger.debug("ActivationReporter: no activation_url configured, skipping")
        :skipped

      url ->
        Task.start(fn -> do_report(url, key_string) end)
        :ok
    end
  end

  defp do_report(url, key_string) do
    body =
      Jason.encode!(%{
        activation: %{
          key_hash: key_hash(key_string),
          machine_id: MachineId.fingerprint(),
          machine_info: MachineId.machine_info()
        }
      })

    case http_post(url, body) do
      {:ok, status} when status in 200..299 ->
        Logger.debug("ActivationReporter: reported successfully")

      {:ok, status} ->
        Logger.debug("ActivationReporter: server returned #{status}, ignoring")

      {:error, reason} ->
        Logger.debug("ActivationReporter: failed to report — #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.debug("ActivationReporter: exception during report — #{inspect(e)}")
  end

  defp http_post(url, body) do
    # Use built-in :httpc — no external HTTP client dependency
    :inets.start()
    if Code.ensure_loaded?(:ssl), do: :ssl.start()

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"user-agent", ~c"MinuteModem/#{Application.spec(:license_core, :vsn)}"}
    ]

    request = {to_charlist(url), headers, ~c"application/json", to_charlist(body)}

    case :httpc.request(:post, request, [{:timeout, 5000}, {:connect_timeout, 3000}], []) do
      {:ok, {{_, status, _}, _, _}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key_hash(key_string) do
    :crypto.hash(:sha256, key_string) |> Base.encode16(case: :lower)
  end

  defp activation_url do
    Application.get_env(:license_core, :activation_url)
  end
end
