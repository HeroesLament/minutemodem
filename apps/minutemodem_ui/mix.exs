defmodule MinuteModemUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :minutemodem_ui,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {MinuteModemUI.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :observer,
        :wx
      ]
    ]
  end

  defp deps do
    [
      {:wx_mvu, path: "../wx_mvu"}
    ]
  end
end
