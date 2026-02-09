defmodule LicenseUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :license_ui,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx]
    ]
  end

  defp deps do
    [
      {:license_core, in_umbrella: true},
      {:wx_mvu, "~> 0.1"}
    ]
  end
end
