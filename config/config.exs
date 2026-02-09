import Config

config :minutemodem_core,
  ecto_repos: [MinuteModemCore.Persistence.Repo]

config :license_api,
  ecto_repos: [LicenseAPI.Repo]

config :license_api, LicenseAPI.Repo,
  database: "license_api_#{config_env()}.db"

config :license_core, :public_key, "fjqLkSIx74mGCix21FP70w_hdWuyEhl2O7_EtbAiGWE"
