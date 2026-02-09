defmodule LicenseAPI.Repo.Migrations.CreateActivations do
  use Ecto.Migration

  def change do
    create table(:activations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key_hash, :string, null: false
      add :machine_id, :string, null: false
      add :machine_hostname, :string
      add :machine_os, :string
      add :machine_arch, :string
      add :ip_address, :string
      add :license_id, references(:licenses, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:activations, [:key_hash])
    create index(:activations, [:machine_id])
    create index(:activations, [:license_id])
    create unique_index(:activations, [:key_hash, :machine_id])
  end
end
