defmodule Eparl.Data.Instance do
  @moduledoc """
  An ePaxos instance representing a single command going through consensus.

  Each instance is uniquely identified by `{replica_id, instance_num}` - the replica
  that initiated consensus and its local sequence number.
  """

  @type id :: {replica_id :: node(), instance_num :: non_neg_integer()}

  @type status :: :preaccepted | :accepted | :committed | :executed

  @type t :: %__MODULE__{
    id: id(),
    command: term(),
    seq: non_neg_integer(),
    deps: MapSet.t(id()),
    status: status(),
    ballot: Eparl.Data.Ballot.t()
  }

  @enforce_keys [:id, :command]
  defstruct [
    :id,
    :command,
    seq: 0,
    deps: MapSet.new(),
    status: :preaccepted,
    ballot: nil
  ]

  @doc """
  Creates a new instance for a command.
  """
  def new(replica_id, instance_num, command) do
    %__MODULE__{
      id: {replica_id, instance_num},
      command: command,
      ballot: Eparl.Data.Ballot.initial(replica_id)
    }
  end
end
