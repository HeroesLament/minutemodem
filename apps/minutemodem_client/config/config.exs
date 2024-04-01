import Config

# Configure Logger to show debug messages
config :logger,
  level: :debug,
  truncate: :infinity

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]
