defmodule MinuteModemCore.Persistence.Repo.Migrations.CreateCallsigns do
  use Ecto.Migration

  def change do
    create table(:callsigns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :addr, :integer, null: false
      add :name, :string
      add :callsign, :string
      add :source, :string, null: false

      add :first_heard, :utc_datetime_usec
      add :last_heard, :utc_datetime_usec
      add :heard_count, :integer, default: 0

      add :notes, :text
      add :protocol_config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:callsigns, [:addr])
    create index(:callsigns, [:callsign])
    create index(:callsigns, [:source])
    create index(:callsigns, [:last_heard])

    create table(:lqa_soundings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :callsign_id, references(:callsigns, type: :binary_id, on_delete: :delete_all), null: false

      add :timestamp, :utc_datetime_usec, null: false
      add :freq_hz, :integer, null: false
      add :snr_db, :float
      add :ber, :float
      add :sinad_db, :float

      add :rig_id, :binary_id
      add :net_id, :binary_id

      add :direction, :string
      add :frame_type, :string
      add :extra, :map, default: %{}
    end

    create index(:lqa_soundings, [:callsign_id])
    create index(:lqa_soundings, [:callsign_id, :timestamp])
    create index(:lqa_soundings, [:timestamp])
    create index(:lqa_soundings, [:freq_hz])
  end
end
