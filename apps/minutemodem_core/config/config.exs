import Config

config :minutemodem_core,
  role: :core,
  audio_enabled: true,
  ui_enabled: false,
  ecto_repos: [MinuteModemCore.Persistence.Repo]

# --- Persistence (Ecto + SQLite) ---
config :minutemodem_core, MinuteModemCore.Persistence.Repo,
  # Use __DIR__ (config/) and go up to app root, then into priv/
  database: Path.expand("../priv/minutemodem_core.db", __DIR__),

  # Embedded / appliance-style DB
  pool_size: 1,

  # Required for concurrent reads
  journal_mode: :wal,

  # Predictable write behavior for control-plane updates
  default_transaction_mode: :immediate,

  # Better behavior under concurrent access
  busy_timeout: 5_000,

  # Enforce relational integrity
  foreign_keys: :on

# --- Logging ---
config :logger,
  level: :info

config :logger, :console,
  format: "$time [$level]$metadata $message\n",
  metadata: [:rig]
