defmodule MinutemodemSimnet.Epoch.Metadata do
  @moduledoc """
  Metadata for an active epoch.

  Used for deterministic reconstruction of channel state
  after failures or relocations.
  """

  @type t :: %__MODULE__{
          epoch_id: integer(),
          seed: integer(),
          t0: non_neg_integer(),
          hf_engine: atom(),
          solar_conditions: map(),
          time_mode: atom() | {atom(), DateTime.t()} | {atom(), number()}
        }

  defstruct [
    :epoch_id,
    :seed,
    :t0,
    hf_engine: :naive,
    solar_conditions: %{ssn: 100, sfi: 150, k_index: 2},
    time_mode: :realtime
  ]

  @doc """
  Creates new epoch metadata.
  """
  def new(opts \\ []) do
    %__MODULE__{
      epoch_id: Keyword.get(opts, :epoch_id, :erlang.unique_integer([:positive, :monotonic])),
      seed: Keyword.get(opts, :seed, :erlang.unique_integer([:positive])),
      t0: Keyword.get(opts, :t0, 0),
      hf_engine: Keyword.get(opts, :hf_engine, :naive),
      solar_conditions: Keyword.get(opts, :solar_conditions, %{ssn: 100, sfi: 150, k_index: 2}),
      time_mode: Keyword.get(opts, :time_mode, :realtime)
    }
  end
end
