defmodule Eparl.Data.ReplicaState do
  @moduledoc """
  State struct for the Replica GenServer.
  """

  @type instance_id :: {node(), non_neg_integer()}

  @type t :: %__MODULE__{
          version: pos_integer(),
          replica_id: node(),
          instance_space: %{node() => %{non_neg_integer() => map()}},
          next_instance: non_neg_integer(),
          max_seq: non_neg_integer(),
          app_state: term(),
          pending_proposals: %{instance_id() => GenServer.from()},
          pending_awaits: %{instance_id() => [{GenServer.from(), atom()}]},
          draining: boolean()
        }

  defstruct [
    :version,
    :replica_id,
    instance_space: %{},
    next_instance: 0,
    max_seq: 0,
    app_state: %{},
    pending_proposals: %{},
    pending_awaits: %{},
    draining: false
  ]
end
