import Config

if config_env() == :prod do
  # Database location
  db_dir = System.get_env("MM_LICENSE_DATA_DIR", "/var/lib/minutemodem-license")
  File.mkdir_p!(db_dir)

  config :license_api, LicenseAPI.Repo,
    database: Path.join(db_dir, "license_api.db")

  # Private key location
  config :license_api, :private_key_path,
    System.get_env("MM_PRIVATE_KEY_PATH", "/etc/minutemodem/license_private.key")
end
