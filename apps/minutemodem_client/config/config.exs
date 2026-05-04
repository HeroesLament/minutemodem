import Config

# Configure Logger to show debug messages
config :logger,
  level: :debug,
  truncate: :infinity

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

config :license_core, :public_key, "fjqLkSIx74mGCix21FP70w_hdWuyEhl2O7_EtbAiGWE"

config :license_core, :enabled, System.get_env("MM_UNLOCKED") != "true"

config :license_core, :activation_url, "http://localhost:4040/api/activations"
