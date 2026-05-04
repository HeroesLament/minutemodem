defmodule LicenseAPI.Repo.Migrations.AddActivationEntitlements do
  use Ecto.Migration

  def change do
    alter table(:licenses) do
      add :max_activations, :integer
    end

    alter table(:activations) do
      add :assertion_string, :text
      add :status, :string, default: "active"
    end
  end
end
