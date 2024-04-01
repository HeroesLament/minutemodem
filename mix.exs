defmodule MinuteModem.MixProject do
  use Mix.Project

  def project do
    [
      name: "MinuteModem",
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: ["lib"]
    ]
  end

  # Umbrella deps are usually empty.
  # Shared deps go in child apps unless truly global.
  defp deps do
    []
  end
end
