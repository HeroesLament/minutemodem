defmodule LicenseCLI.Client do
  @moduledoc """
  HTTP client for the LicenseAPI REST endpoints.
  Uses built-in :httpc so we don't need an HTTP library dep.
  """

  def get(path, config) do
    request(:get, path, nil, config)
  end

  def post(path, body, config) do
    request(:post, path, body, config)
  end

  def delete(path, config) do
    request(:delete, path, nil, config)
  end

  defp request(method, path, body, config) do
    :inets.start()
    :ssl.start()

    url = String.to_charlist("#{config.api_url}#{path}")

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{config.token}")},
      {~c"accept", ~c"application/json"}
    ]

    http_opts = [
      {:timeout, 15_000},
      {:connect_timeout, 5_000},
      {:ssl, [{:verify, :verify_none}]}
    ]

    result =
      case method do
        :get ->
          :httpc.request(:get, {url, headers}, http_opts, [])

        :delete ->
          :httpc.request(:delete, {url, headers}, http_opts, [])

        :post ->
          json_body = if body, do: Jason.encode!(body), else: "{}"
          :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(json_body)}, http_opts, [])
      end

    case result do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        decoded = resp_body |> to_string() |> Jason.decode!()
        {:ok, status, decoded}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
