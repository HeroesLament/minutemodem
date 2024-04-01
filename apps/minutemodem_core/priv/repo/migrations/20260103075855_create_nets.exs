defmodule MinuteModemCore.Persistence.Repo.Migrations.CreateNets do
  use Ecto.Migration

  def change do
    create table(:nets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :enabled, :boolean, default: true, null: false

      add :net_type, :string, null: false

      add :channels, :map, default: %{}
      add :members, :map, default: %{}
      add :timing_config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:nets, [:name])
  end
end
