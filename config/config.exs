import Config

config :minutemodem_core,
  ecto_repos: [MinuteModemCore.Persistence.Repo]

config :license_api,
  ecto_repos: [LicenseAPI.Repo]

config :license_api, LicenseAPI.Repo,
  database: "license_api_#{config_env()}.db"

config :license_core, :public_key, "fjqLkSIx74mGCix21FP70w_hdWuyEhl2O7_EtbAiGWE"

config :license_core, :enabled, System.get_env("MM_UNLOCKED") != "true"

config :license_core, :activation_url, "http://localhost:4040/api/activations"

config :license_api, :private_key_path, "./dev_license_private.key"
