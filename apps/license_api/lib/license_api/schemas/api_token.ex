defmodule LicenseAPI.Schemas.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "api_tokens" do
    field :label, :string
    field :token_hash, :string
    field :token_prefix, :string
    field :scope, :string, default: "admin"
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:label, :token_hash, :token_prefix, :scope, :active])
    |> validate_required([:label, :token_hash, :token_prefix])
    |> validate_inclusion(:scope, ~w(admin webhook))
  end
end
