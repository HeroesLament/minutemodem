defmodule MinuteModemCore.Persistence.Schemas.Net do
  @moduledoc """
  Persisted representation of an ALE network.

  A net defines a set of channels (frequencies) and members (stations)
  that participate in coordinated ALE operations.

  ## Net Types

  - `ale_2g` - MIL-STD-188-141A (legacy)
  - `ale_3g` - MIL-STD-188-141B
  - `ale_4g` - MIL-STD-188-141D (current, with WALE)

  ## Channels

  List of frequency definitions:

      [
        %{
          "freq_hz" => 7102000,
          "name" => "40M-ALE-1",
          "band" => "40m",
          "mode" => "usb",
          "usage" => "night_regional"
        },
        ...
      ]

  ## Members

  List of station definitions:

      [
        %{
          "addr" => 0x1234,
          "name" => "HOME",
          "callsign" => "KX0XXX",
          "role" => "net_control"
        },
        ...
      ]

  ## Timing Config

  Optional timing overrides:

      %{
        "slot_time_ms" => 1800,
        "scan_dwell_ms" => 500,
        "lbt_time_ms" => 200,
        "response_timeout_ms" => 2000
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_net_types ~w(ale_2g ale_3g ale_4g)
  @valid_modes ~w(usb lsb am)
  @valid_roles ~w(net_control member relay)

  schema "nets" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :net_type, :string
    field :channels, {:array, :map}, default: []
    field :members, {:array, :map}, default: []
    field :timing_config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(net, attrs) do
    net
    |> cast(attrs, [
      :name,
      :enabled,
      :net_type,
      :channels,
      :members,
      :timing_config
    ])
    |> validate_required([:name, :net_type])
    |> validate_inclusion(:net_type, @valid_net_types)
    |> validate_channels()
    |> validate_members()
    |> validate_timing_config()
    |> unique_constraint(:name)
  end

  defp validate_channels(changeset) do
    channels = get_field(changeset, :channels) || []

    errors =
      channels
      |> Enum.with_index()
      |> Enum.flat_map(fn {ch, idx} ->
        validate_channel(ch, idx)
      end)

    Enum.reduce(errors, changeset, fn {field, msg}, cs ->
      add_error(cs, field, msg)
    end)
  end

  defp validate_channel(ch, idx) when is_map(ch) do
    errors = []

    errors =
      case Map.get(ch, "freq_hz") do
        nil -> [{:channels, "channel #{idx}: missing freq_hz"} | errors]
        freq when is_integer(freq) and freq > 0 -> errors
        _ -> [{:channels, "channel #{idx}: freq_hz must be positive integer"} | errors]
      end

    errors =
      case Map.get(ch, "mode") do
        nil -> errors
        mode when mode in @valid_modes -> errors
        _ -> [{:channels, "channel #{idx}: invalid mode"} | errors]
      end

    errors
  end

  defp validate_channel(_, idx) do
    [{:channels, "channel #{idx}: must be a map"}]
  end

  defp validate_members(changeset) do
    members = get_field(changeset, :members) || []

    errors =
      members
      |> Enum.with_index()
      |> Enum.flat_map(fn {member, idx} ->
        validate_member(member, idx)
      end)

    Enum.reduce(errors, changeset, fn {field, msg}, cs ->
      add_error(cs, field, msg)
    end)
  end

  defp validate_member(member, idx) when is_map(member) do
    errors = []

    errors =
      case Map.get(member, "addr") do
        nil -> [{:members, "member #{idx}: missing addr"} | errors]
        addr when is_integer(addr) and addr >= 0 and addr < 0x10000 -> errors
        _ -> [{:members, "member #{idx}: addr must be 0-65535"} | errors]
      end

    errors =
      case Map.get(member, "role") do
        nil -> errors
        role when role in @valid_roles -> errors
        _ -> [{:members, "member #{idx}: invalid role"} | errors]
      end

    errors
  end

  defp validate_member(_, idx) do
    [{:members, "member #{idx}: must be a map"}]
  end

  defp validate_timing_config(changeset) do
    config = get_field(changeset, :timing_config) || %{}

    timing_fields = [
      {"slot_time_ms", 100, 10000},
      {"scan_dwell_ms", 50, 5000},
      {"lbt_time_ms", 50, 2000},
      {"response_timeout_ms", 500, 30000}
    ]

    errors =
      Enum.flat_map(timing_fields, fn {field, min, max} ->
        case Map.get(config, field) do
          nil -> []
          val when is_integer(val) and val >= min and val <= max -> []
          _ -> [{:timing_config, "#{field} must be #{min}-#{max}"}]
        end
      end)

    Enum.reduce(errors, changeset, fn {field, msg}, cs ->
      add_error(cs, field, msg)
    end)
  end

  @doc """
  Build a default timing config for a net type.
  """
  def default_timing_config("ale_4g") do
    %{
      "slot_time_ms" => 1800,
      "scan_dwell_ms" => 500,
      "lbt_time_ms" => 200,
      "response_timeout_ms" => 2000
    }
  end

  def default_timing_config("ale_3g") do
    %{
      "slot_time_ms" => 2000,
      "scan_dwell_ms" => 500,
      "lbt_time_ms" => 200,
      "response_timeout_ms" => 3000
    }
  end

  def default_timing_config("ale_2g") do
    %{
      "slot_time_ms" => 2000,
      "scan_dwell_ms" => 392,
      "lbt_time_ms" => 200,
      "response_timeout_ms" => 5000
    }
  end

  def default_timing_config(_), do: default_timing_config("ale_4g")

  @doc """
  Build a sample scanlist for testing.
  """
  def sample_channels do
    [
      %{"freq_hz" => 3_596_000, "name" => "80M-ALE-1", "band" => "80m", "mode" => "usb", "usage" => "night_nvis"},
      %{"freq_hz" => 3_791_000, "name" => "80M-ALE-2", "band" => "80m", "mode" => "usb", "usage" => "night_nvis"},
      %{"freq_hz" => 5_357_000, "name" => "60M-CH1", "band" => "60m", "mode" => "usb", "usage" => "all_day_nvis"},
      %{"freq_hz" => 5_371_500, "name" => "60M-CH2", "band" => "60m", "mode" => "usb", "usage" => "all_day_nvis"},
      %{"freq_hz" => 7_102_000, "name" => "40M-ALE-1", "band" => "40m", "mode" => "usb", "usage" => "night_regional"},
      %{"freq_hz" => 7_185_000, "name" => "40M-ALE-2", "band" => "40m", "mode" => "usb", "usage" => "night_regional"},
      %{"freq_hz" => 7_296_000, "name" => "40M-ALE-3", "band" => "40m", "mode" => "usb", "usage" => "night_regional"},
      %{"freq_hz" => 10_145_000, "name" => "30M-ALE-1", "band" => "30m", "mode" => "usb", "usage" => "transition"},
      %{"freq_hz" => 14_109_000, "name" => "20M-ALE-1", "band" => "20m", "mode" => "usb", "usage" => "day_skywave"},
      %{"freq_hz" => 14_346_000, "name" => "20M-ALE-2", "band" => "20m", "mode" => "usb", "usage" => "day_skywave"},
      %{"freq_hz" => 18_106_000, "name" => "17M-ALE-1", "band" => "17m", "mode" => "usb", "usage" => "day_dx"},
      %{"freq_hz" => 21_096_000, "name" => "15M-ALE-1", "band" => "15m", "mode" => "usb", "usage" => "day_dx"},
      %{"freq_hz" => 24_926_000, "name" => "12M-ALE-1", "band" => "12m", "mode" => "usb", "usage" => "day_dx_solar_max"},
      %{"freq_hz" => 28_146_000, "name" => "10M-ALE-1", "band" => "10m", "mode" => "usb", "usage" => "day_sporadic"}
    ]
  end
end
