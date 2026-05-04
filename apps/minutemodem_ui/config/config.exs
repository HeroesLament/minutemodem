import Config

config :minutemodem_ui,
  role: :ui,
  enabled: true,
  wx: [
    title: "MinuteModem",
    width: 1024,
    height: 768
  ]

config :logger,
  level: :info

config :license_core, :public_key, "fjqLkSIx74mGCix21FP70w_hdWuyEhl2O7_EtbAiGWE"
config :license_core, :enabled, System.get_env("MM_UNLOCKED") != "true"
config :license_core, :activation_url, "http://localhost:4040/api/activations"
