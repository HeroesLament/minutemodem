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
      {:wx_mvu, path: "C:/build/wx_mvu", override: true},
      {:minutemodem_core, in_umbrella: true},

      # Audio I/O (operator mic + speaker)
      {:membrane_core, "~> 1.0"},

      # Rustler for DSP NIFs (spectrogram, constellation, meters)
      {:rustler, "~> 0.37"},

      # License management scene
      {:license_ui, in_umbrella: true},

      # bundlex override for Membrane
      {:bundlex, path: "C:/build/bundlex", override: true},

      # shmex + unifex override for Membrane
      {:membrane_portaudio_plugin, path: "C:/build/membrane_portaudio_plugin", override: true},
      {:membrane_common_c, path: "C:/build/membrane_common_c", override: true},
      {:unifex, path: "C:/build/unifex", override: true},
      {:shmex, path: "C:/build/shmex", override: true}
    ]
  end
end
