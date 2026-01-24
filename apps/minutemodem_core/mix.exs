defmodule MinuteModemCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :minutemodem_core,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {MinuteModemCore.Application, []},
      extra_applications: [
        :logger,
        :membrane_core,
        :ecto_sql
      ]
    ]
  end

  defp deps do
    [
      # Membrane core runtime
      {:membrane_core, "~> 1.0"},

      # Audio I/O (mic + speakers)
      {:membrane_portaudio_plugin, "~> 0.16"},

      # Persistence (Ecto + SQLite)
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},

      # State machines
      {:gen_state_machine, "~> 3.0"},

      # Rustler for Rust NIFs
      {:rustler, "~> 0.37"}
    ]
  end
end
