defmodule MinutemodemSimnet.MixProject do
  use Mix.Project

  def project do
    [
      app: :minutemodem_simnet,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MinutemodemSimnet.Application, []}
    ]
  end

  defp deps do
    [
      {:highlander, "~> 0.2"},
      {:horde, "~> 0.9"},
      {:eparl, in_umbrella: true},
      {:gen_state_machine, "~> 3.0"},
      {:telemetry, "~> 1.0"},
      {:libcluster, "~> 3.3"},
      {:rustler, "~> 0.37"}
    ]
  end
end
