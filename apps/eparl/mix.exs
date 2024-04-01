defmodule Eparl.MixProject do
  use Mix.Project

  def project do
    [
      app: :eparl,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Eparl.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_state_machine, "~> 3.0"},

      # Dev/Test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Eparl",
      extras: ["README.md"]
    ]
  end
end
