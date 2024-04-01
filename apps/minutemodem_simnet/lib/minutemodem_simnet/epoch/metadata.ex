defmodule MinutemodemSimnet.Epoch.Metadata do
  @moduledoc """
  Metadata for an active epoch.

  Used for deterministic reconstruction of channel state
  after failures or relocations.
  """

  @type t :: %__MODULE__{
          epoch_id: integer(),
          seed: integer(),
          t0: non_neg_integer()
        }

  defstruct [
    :epoch_id,
    :seed,
    :t0
  ]

  @doc """
  Creates new epoch metadata.
  """
  def new(opts \\ []) do
    %__MODULE__{
      epoch_id: Keyword.get(opts, :epoch_id, :erlang.unique_integer([:positive, :monotonic])),
      seed: Keyword.get(opts, :seed, :erlang.unique_integer([:positive])),
      t0: Keyword.get(opts, :t0, 0)
    }
  end
end
