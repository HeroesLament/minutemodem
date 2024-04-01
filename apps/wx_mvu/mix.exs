defmodule WxMVU.MixProject do
  use Mix.Project

  def project do
    [
      app: :wx_mvu,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx],
      mod: {WxMVU.Application, []}
    ]
  end

  defp deps do
    [
      {:wx_ex, "~> 0.5.0"}
    ]
  end
end
