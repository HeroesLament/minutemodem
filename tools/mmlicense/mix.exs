defmodule MMLicense.MixProject do
  use Mix.Project

  def project do
    [
      app: :mmlicense,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  defp escript do
    [
      main_module: LicenseCLI,
      name: "mmlicense"
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:owl, "~> 0.13"}
    ]
  end
end
