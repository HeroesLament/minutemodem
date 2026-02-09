defmodule MinuteModem.MixProject do
  use Mix.Project

  def project do
    [
      name: "MinuteModem",
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: ["lib"],
      releases: releases()
    ]
  end

  defp releases do
    [
      minutemodem_station: [
        applications: [
          minutemodem_core: :permanent,
          minutemodem_ui: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          license_ui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true
      ],
      minutemodem_remote: [
        applications: [
          minutemodem_ui: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          license_ui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true
      ],
      minutemodem_core: [
        applications: [
          minutemodem_core: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true
      ],
      license_api: [
        applications: [
          license_api: :permanent,
          license_core: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true
      ]
    ]
  end

  # Umbrella deps are usually empty.
  # Shared deps go in child apps unless truly global.
  defp deps do
    []
  end
end
