defmodule LicenseAPI.Repo.Migrations.CreateInitialTables do
  use Ecto.Migration

  def change do
    create table(:licenses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :tier, :string, null: false, default: "standard"
      add :expires, :date, null: false
      add :key_string, :text, null: false
      add :status, :string, null: false, default: "active"
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:licenses, [:email])
    create index(:licenses, [:status])

    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :scope, :string, null: false, default: "admin"
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
  end
end
