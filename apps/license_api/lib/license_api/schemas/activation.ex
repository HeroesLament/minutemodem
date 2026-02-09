defmodule LicenseAPI.Schemas.Activation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "activations" do
    field :key_hash, :string
    field :machine_id, :string
    field :machine_hostname, :string
    field :machine_os, :string
    field :machine_arch, :string
    field :ip_address, :string

    belongs_to :license, LicenseAPI.Schemas.License, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(activation, attrs) do
    activation
    |> cast(attrs, [:key_hash, :machine_id, :machine_hostname, :machine_os, :machine_arch, :ip_address, :license_id])
    |> validate_required([:key_hash, :machine_id])
  end
end
