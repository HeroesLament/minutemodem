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
      extra_applications: [:logger, :wx]
      # No mod: - start manually via MinuteModemClient.start()
    ]
  end

  defp deps do
    [
      {:wx_mvu, in_umbrella: true},
      {:gen_state_machine, "~> 3.0"}
    ]
  end
end
