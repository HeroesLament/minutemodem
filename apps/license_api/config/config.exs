import Config

config :license_api, LicenseAPI.Repo,
  database: "license_api_#{config_env()}.db"

config :license_api, ecto_repos: [LicenseAPI.Repo]

# Private key path — set in runtime.exs for prod
config :license_api, :private_key_path, nil

config :license_api, :private_key_path, "./dev_license_private.key"
