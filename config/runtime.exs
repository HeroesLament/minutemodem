# config/runtime.exs
import Config

if config_env() == :prod do
  data_dir =
    System.get_env("MM_DATA_DIR") ||
      Path.join(System.get_env("HOME", "/tmp"), "Library/Application Support/MinuteModem")

  File.mkdir_p!(data_dir)

  config :minutemodem_core, MinuteModemCore.Persistence.Repo,
    database: Path.join(data_dir, "minutemodem.db")

  # For remote UI release
  if core_node = System.get_env("MM_CORE_NODE") do
    config :minutemodem_ui, :core_node, String.to_atom(core_node)
  end
end
