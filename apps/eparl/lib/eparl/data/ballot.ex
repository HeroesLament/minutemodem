# data/ballot.ex
defmodule Eparl.Data.Ballot do
  @moduledoc """
  Ballot numbers for ePaxos recovery protocol.

  Ballots are totally ordered: compare by (epoch, counter, replica_id).

  During normal operation, instances use their initial ballot (epoch 0).
  During recovery, we increment the epoch to "take over" an instance.
  """

  @type t :: %__MODULE__{
    epoch: non_neg_integer(),
    counter: non_neg_integer(),
    replica_id: node()
  }

  @enforce_keys [:replica_id]
  defstruct epoch: 0, counter: 0, replica_id: nil

  @doc """
  Create initial ballot for a replica.
  """
  def initial(replica_id) do
    %__MODULE__{epoch: 0, counter: 0, replica_id: replica_id}
  end

  @doc """
  Increment ballot epoch (used during recovery).
  """
  def increment(%__MODULE__{} = ballot) do
    %{ballot | epoch: ballot.epoch + 1, counter: 0}
  end

  @doc """
  Create a ballot higher than the given one.
  Used when taking over recovery from another replica.
  """
  def higher_than(%__MODULE__{} = other, replica_id) do
    %__MODULE__{epoch: other.epoch + 1, counter: 0, replica_id: replica_id}
  end

  def higher_than(nil, replica_id) do
    initial(replica_id)
  end

  @doc """
  Compare two ballots.
  Returns :lt, :eq, or :gt.
  """
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    cond do
      a.epoch < b.epoch -> :lt
      a.epoch > b.epoch -> :gt
      a.counter < b.counter -> :lt
      a.counter > b.counter -> :gt
      a.replica_id < b.replica_id -> :lt
      a.replica_id > b.replica_id -> :gt
      true -> :eq
    end
  end

  def compare(nil, %__MODULE__{}), do: :lt
  def compare(%__MODULE__{}, nil), do: :gt
  def compare(nil, nil), do: :eq

  @doc """
  Check if ballot a >= ballot b.
  """
  def gte?(a, b) do
    compare(a, b) in [:gt, :eq]
  end

  @doc """
  Check if ballot a > ballot b.
  """
  def gt?(a, b) do
    compare(a, b) == :gt
  end
end
