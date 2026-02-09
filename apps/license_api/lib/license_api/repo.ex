defmodule LicenseAPI.Repo do
  use Ecto.Repo,
    otp_app: :license_api,
    adapter: Ecto.Adapters.SQLite3
end
