defmodule LicenseTUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :license_tui,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:license_core, in_umbrella: true},
      {:owl, "~> 0.13"}
    ]
  end
end
