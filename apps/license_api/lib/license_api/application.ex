defmodule LicenseAPI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LicenseAPI.Repo,
      {Phoenix.PubSub, name: LicenseAPI.PubSub},
      LicenseAPI.KeyStore,
      {Plug.Cowboy,
       scheme: :http,
       plug: LicenseAPI.Router,
       options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: LicenseAPI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    case System.get_env("LICENSE_API_PORT") do
      nil -> 4040
      p -> String.to_integer(p)
    end
  end
end
