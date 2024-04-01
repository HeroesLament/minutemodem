defmodule MinutemodemSimnet.Group.Definition do
  @moduledoc """
  Defines a simulator group - a synthetic propagation environment.

  Rigs assigned to a group share correlated channel conditions
  (MUF curves, geo model, diurnal effects, noise floor).
  """

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          name: String.t(),
          muf_curve: map() | nil,
          geo_model: map() | nil,
          noise_floor_db: float(),
          disturbance_index: float(),
          channel_defaults: map()
        }

  defstruct [
    :id,
    :name,
    :muf_curve,
    :geo_model,
    noise_floor_db: -100.0,
    disturbance_index: 0.0,
    channel_defaults: %{}
  ]

  @doc """
  Creates a new group definition.
  """
  def new(id, opts \\ []) do
    %__MODULE__{
      id: id,
      name: Keyword.get(opts, :name, to_string(id)),
      muf_curve: Keyword.get(opts, :muf_curve),
      geo_model: Keyword.get(opts, :geo_model),
      noise_floor_db: Keyword.get(opts, :noise_floor_db, -100.0),
      disturbance_index: Keyword.get(opts, :disturbance_index, 0.0),
      channel_defaults: Keyword.get(opts, :channel_defaults, %{})
    }
  end

  @doc """
  Merges channel defaults for this group with per-channel overrides.
  """
  def merge_channel_params(%__MODULE__{} = group, overrides) do
    Map.merge(group.channel_defaults, overrides)
  end
end
