import Config

if config_env() == :prod do
  data_dir =
    System.get_env("MM_DATA_DIR") ||
      case :os.type() do
        {:win32, _} ->
          base =
            System.get_env("LOCALAPPDATA") ||
              System.get_env("APPDATA") ||
              Path.join(System.get_env("USERPROFILE", "C:/"), "AppData/Local")

          Path.join(base, "MinuteModem")

        {:unix, :darwin} ->
          Path.join(
            System.get_env("HOME", "/tmp"),
            "Library/Application Support/MinuteModem"
          )

        _ ->
          Path.join(System.get_env("HOME", "/tmp"), ".local/share/MinuteModem")
      end

  File.mkdir_p!(data_dir)

  config :minutemodem_core, MinuteModemCore.Persistence.Repo,
    database: Path.join(data_dir, "minutemodem.db")

  # CoreClient core_node selection:
  #   - Remote UI release: set MM_CORE_NODE to the core node atom
  #   - Monolithic release (UI + Core in same VM): default to local node()
  core_node =
    case System.get_env("MM_CORE_NODE") do
      nil -> node()
      str -> String.to_atom(str)
    end

  config :minutemodem_ui, :core_node, core_node
end
