defmodule MinuteModemCore.Persistence.Schemas.Rig do
  @moduledoc """
  Persisted representation of a radio rig.

  A rig is the authoritative configuration unit that drives
  runtime process trees (ALE, audio, control).

  ## Simnet Configuration

  For test/simulator rigs, `control_config` can include physical
  parameters for channel simulation:

      %{
        "location" => [lat, lon],           # GPS coordinates
        "antenna" => %{
          "type" => "dipole",               # dipole, vertical, inverted_v
          "height_wavelengths" => 0.5
        },
        "tx_power_watts" => 100,
        "noise_floor_dbm" => -100.0
      }

  See `MinuteModemCore.Rig.SimnetBridge` for defaults.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_rig_types ~w(test hf hf_rx vhf)
  @valid_protocol_stacks ~w(ale_2g ale_3g ale_4g stanag_5066 packet aprs)
  @valid_control_types ~w(simulator rigctld flrig)
  @valid_antenna_types ~w(dipole vertical inverted_v yagi loop)

  schema "rigs" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :rig_type, :string
    field :protocol_stack, :string
    field :self_addr, :integer
    field :control_type, :string
    field :control_config, :map, default: %{}
    field :rx_audio, :string
    field :tx_audio, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rig, attrs) do
    rig
    |> cast(attrs, [
      :name,
      :enabled,
      :rig_type,
      :protocol_stack,
      :self_addr,
      :control_type,
      :control_config,
      :rx_audio,
      :tx_audio
    ])
    |> validate_required([:name, :rig_type])
    |> validate_inclusion(:rig_type, @valid_rig_types)
    |> validate_inclusion(:protocol_stack, @valid_protocol_stacks ++ [nil])
    |> validate_inclusion(:control_type, @valid_control_types ++ [nil])
    |> validate_self_addr()
    |> validate_control_config()
    |> unique_constraint(:name)
  end

  defp validate_self_addr(changeset) do
    case get_field(changeset, :self_addr) do
      nil -> changeset
      addr when addr >= 0 and addr < 0x10000 -> changeset
      _ -> add_error(changeset, :self_addr, "must be 0-65535")
    end
  end

  defp validate_control_config(changeset) do
    config = get_field(changeset, :control_config) || %{}
    rig_type = get_field(changeset, :rig_type)

    changeset
    |> validate_simnet_location(config)
    |> validate_simnet_antenna(config)
    |> validate_simnet_power(config, rig_type)
  end

  defp validate_simnet_location(changeset, config) do
    case Map.get(config, "location") do
      nil -> changeset
      [lat, lon] when is_number(lat) and is_number(lon) ->
        if lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 do
          changeset
        else
          add_error(changeset, :control_config, "location must be valid GPS coordinates")
        end
      _ ->
        add_error(changeset, :control_config, "location must be [lat, lon]")
    end
  end

  defp validate_simnet_antenna(changeset, config) do
    case Map.get(config, "antenna") do
      nil -> changeset
      %{"type" => type} when type in @valid_antenna_types -> changeset
      %{"type" => _} ->
        add_error(changeset, :control_config,
          "antenna type must be one of: #{Enum.join(@valid_antenna_types, ", ")}")
      %{} ->
        add_error(changeset, :control_config, "antenna must include type")
      _ ->
        changeset
    end
  end

  defp validate_simnet_power(changeset, config, rig_type) when rig_type in ["test", "simulator"] do
    case Map.get(config, "tx_power_watts") do
      nil -> changeset
      power when is_number(power) and power > 0 and power <= 10000 -> changeset
      _ -> add_error(changeset, :control_config, "tx_power_watts must be 1-10000")
    end
  end

  defp validate_simnet_power(changeset, _config, _rig_type), do: changeset

  # --- Convenience functions for building simnet config ---

  @doc """
  Build a simnet-enabled control_config map.

  ## Examples

      Rig.simnet_config(
        location: {64.84, -147.72},
        antenna: :dipole,
        tx_power: 100
      )
      #=> %{
        "location" => [64.84, -147.72],
        "antenna" => %{"type" => "dipole", "height_wavelengths" => 0.5},
        "tx_power_watts" => 100,
        "noise_floor_dbm" => -100.0
      }
  """
  def simnet_config(opts \\ []) do
    location = Keyword.get(opts, :location)
    antenna = Keyword.get(opts, :antenna, :dipole)
    height = Keyword.get(opts, :height_wavelengths, 0.5)
    tx_power = Keyword.get(opts, :tx_power, 100)
    noise_floor = Keyword.get(opts, :noise_floor, -100.0)

    config = %{
      "tx_power_watts" => tx_power,
      "noise_floor_dbm" => noise_floor,
      "antenna" => %{
        "type" => to_string(antenna),
        "height_wavelengths" => height
      }
    }

    case location do
      {lat, lon} -> Map.put(config, "location", [lat, lon])
      [lat, lon] -> Map.put(config, "location", [lat, lon])
      nil -> config
    end
  end
end
