defmodule MinuteModemCore.Persistence.Schemas.Callsign do
  @moduledoc """
  Directory entry for a known or heard station.

  ## Sources

  - `manual` - Operator-created entry
  - `sounding` - First detected via ALE sounding
  - `inbound_call` - First detected via incoming call
  - `imported` - Imported from codeplug or external source

  ## Protocol Config

  Holds protocol-specific settings, e.g. for S5066:

      %{
        "s5066" => %{
          "node_id" => 1,
          "max_data_rate" => 4800,
          "arq_enabled" => true
        }
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias MinuteModemCore.Persistence.Schemas.LqaSounding

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_sources ~w(manual sounding inbound_call imported)

  schema "callsigns" do
    field :addr, :integer
    field :name, :string
    field :callsign, :string
    field :source, :string

    field :first_heard, :utc_datetime_usec
    field :last_heard, :utc_datetime_usec
    field :heard_count, :integer, default: 0

    field :notes, :string
    field :protocol_config, :map, default: %{}

    has_many :lqa_soundings, LqaSounding

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(callsign, attrs) do
    callsign
    |> cast(attrs, [
      :addr,
      :name,
      :callsign,
      :source,
      :first_heard,
      :last_heard,
      :heard_count,
      :notes,
      :protocol_config
    ])
    |> validate_required([:addr, :source])
    |> validate_inclusion(:source, @valid_sources)
    |> validate_addr()
    |> unique_constraint(:addr)
  end

  defp validate_addr(changeset) do
    case get_field(changeset, :addr) do
      nil -> changeset
      addr when is_integer(addr) and addr >= 0 and addr < 0x10000 -> changeset
      _ -> add_error(changeset, :addr, "must be 0-65535")
    end
  end

  @doc """
  Create a changeset for a newly heard station.
  """
  def heard_changeset(callsign, attrs) do
    now = DateTime.utc_now()

    attrs = attrs
    |> Map.put_new(:first_heard, now)
    |> Map.put(:last_heard, now)

    callsign
    |> changeset(attrs)
    |> increment_heard_count()
  end

  defp increment_heard_count(changeset) do
    current = get_field(changeset, :heard_count) || 0
    put_change(changeset, :heard_count, current + 1)
  end
end
