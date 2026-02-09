defmodule LicenseAPI.MixProject do
  use Mix.Project

  def project do
    [
      app: :license_api,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {LicenseAPI.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp deps do
    [
      {:license_core, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"},
      {:bcrypt_elixir, "~> 3.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
