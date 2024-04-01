defmodule MinuteModemCore.Persistence.Repo.Migrations.CreateRigs do
  use Ecto.Migration

  def change do
    create table(:rigs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Human-facing identity
      add :name, :string, null: false
      add :enabled, :boolean, default: true, null: false

      # Rig type and protocol stack
      add :rig_type, :string, null: false
      add :protocol_stack, :string
      add :self_addr, :integer

      # Control plane
      add :control_type, :string
      add :control_config, :map

      # Audio bindings (logical names)
      add :rx_audio, :string
      add :tx_audio, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:rigs, [:name])
  end
end
