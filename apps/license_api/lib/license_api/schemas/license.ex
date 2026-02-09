defmodule LicenseAPI.Schemas.License do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "licenses" do
    field :email, :string
    field :tier, :string, default: "standard"
    field :expires, :date
    field :key_string, :string
    field :status, :string, default: "active"
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(license, attrs) do
    license
    |> cast(attrs, [:email, :tier, :expires, :notes])
    |> validate_required([:email, :tier, :expires])
    |> validate_inclusion(:status, ~w(active revoked expired refunded superseded transferred))
    |> validate_format(:email, ~r/@/)
  end

  def revoke_changeset(license) do
    change(license, status: "revoked")
  end
end
