defmodule MinuteModemClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :minutemodem_client,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {MinuteModemClient.Application, []},
      extra_applications: [:logger, :wx]
    ]
  end

  defp deps do
    [
      {:wx_mvu, path: "C:/build/wx_mvu", override: true},
      {:gen_state_machine, "~> 3.0"},
      {:license_ui, in_umbrella: true}
    ]
  end
end
