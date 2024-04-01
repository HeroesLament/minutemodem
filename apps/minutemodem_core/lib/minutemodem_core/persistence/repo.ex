defmodule MinuteModemCore.Persistence.Repo do
  use Ecto.Repo,
    otp_app: :minutemodem_core,
    adapter: Ecto.Adapters.SQLite3
end
