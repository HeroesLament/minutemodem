defmodule LicenseCore.ActivationReporter do
  @moduledoc """
  Requests a signed activation assertion from the license API server.

  Configure the API URL:

      config :license_core, :activation_url, "https://license.minutemodem.com/api/activations"

  If not configured, returns {:error, :not_configured}.
  """

  require Logger

  alias LicenseCore.{MachineId, Assertion}

  @doc """
  Request a signed assertion from the license server.
  Synchronous — blocks until the server responds or times out.
  """
  def request_assertion(key_string) do
    case activation_url() do
      nil ->
        {:error, :not_configured}

      url ->
        do_request(url, key_string)
    end
  end

  defp do_request(url, key_string) do
    machine_info = MachineId.machine_info()

    body = %{
      "activation" => %{
        "key_hash" => Assertion.key_hash(key_string),
        "machine_id" => MachineId.fingerprint(),
        "machine_info" => %{
          "hostname" => machine_info.hostname,
          "os" => machine_info.os,
          "arch" => machine_info.arch
        }
      }
    }

    case Req.post(url, json: body, connect_options: [timeout: 5_000], receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"assertion" => assertion_string}}} ->
        {:ok, assertion_string}

      {:ok, %{status: 200, body: %{"error" => "denied"}}} ->
        {:error, :denied}

      {:ok, %{status: 403}} ->
        {:error, :denied}

      {:ok, %{status: 409, body: resp}} ->
        Logger.warning("Activation denied: #{resp["error"] || "seat limit exceeded"}")
        {:error, :seat_limit_exceeded}

      {:ok, %{status: status}} ->
        Logger.debug("ActivationReporter: server returned #{status}")
        {:error, {:server_error, status}}

      {:error, reason} ->
        Logger.debug("ActivationReporter: request failed — #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  rescue
    e ->
      Logger.debug("ActivationReporter: exception — #{inspect(e)}")
      {:error, {:exception, e}}
  end

  defp activation_url do
    Application.get_env(:license_core, :activation_url)
  end
end
