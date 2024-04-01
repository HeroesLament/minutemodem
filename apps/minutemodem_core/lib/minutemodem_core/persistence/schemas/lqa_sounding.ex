defmodule MinuteModemCore.Persistence.Schemas.LqaSounding do
  @moduledoc """
  Link Quality Analysis sounding record.

  Tracks signal quality measurements for a callsign over time.
  Used for automatic channel selection and link quality history.

  ## Direction

  - `rx` - We received a frame from this station
  - `tx` - We transmitted and got acknowledgment

  ## Frame Types

  - `sounding` - ALE sounding/probe
  - `call` - ALE call (LSU_Req)
  - `response` - ALE response (LSU_Conf)
  - `data` - Data frame during linked state
  - `terminate` - Link termination
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias MinuteModemCore.Persistence.Schemas.Callsign

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_directions ~w(rx tx)
  @valid_frame_types ~w(sounding call response data terminate)

  schema "lqa_soundings" do
    belongs_to :callsign, Callsign

    field :timestamp, :utc_datetime_usec
    field :freq_hz, :integer
    field :snr_db, :float
    field :ber, :float
    field :sinad_db, :float

    field :rig_id, :binary_id
    field :net_id, :binary_id

    field :direction, :string
    field :frame_type, :string
    field :extra, :map, default: %{}
  end

  def changeset(sounding, attrs) do
    sounding
    |> cast(attrs, [
      :callsign_id,
      :timestamp,
      :freq_hz,
      :snr_db,
      :ber,
      :sinad_db,
      :rig_id,
      :net_id,
      :direction,
      :frame_type,
      :extra
    ])
    |> validate_required([:callsign_id, :timestamp, :freq_hz])
    |> validate_inclusion(:direction, @valid_directions ++ [nil])
    |> validate_inclusion(:frame_type, @valid_frame_types ++ [nil])
    |> foreign_key_constraint(:callsign_id)
  end

  @doc """
  Create a sounding record from an ALE receive event.
  """
  def from_ale_rx(callsign_id, freq_hz, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      callsign_id: callsign_id,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      freq_hz: freq_hz,
      snr_db: Keyword.get(opts, :snr_db),
      ber: Keyword.get(opts, :ber),
      sinad_db: Keyword.get(opts, :sinad_db),
      rig_id: Keyword.get(opts, :rig_id),
      net_id: Keyword.get(opts, :net_id),
      direction: "rx",
      frame_type: Keyword.get(opts, :frame_type, "sounding"),
      extra: Keyword.get(opts, :extra, %{})
    })
  end
end
