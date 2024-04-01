# data/command.ex
defmodule Eparl.Data.Command do
  @moduledoc """
  Behaviour for user-defined commands.

  Users implement this to define their replicated state machine.
  The key insight of ePaxos is that non-interfering commands can
  be reordered, so `interferes?/2` determines execution order.
  """

  @doc """
  Returns true if the two commands interfere (cannot be reordered).

  For a KV store: operations on the same key interfere.
  For a counter: all increments interfere with each other.
  """
  @callback interferes?(command :: term(), command :: term()) :: boolean()

  @doc """
  Execute a command against the current state.

  Returns `{result, new_state}` where result is returned to the caller.
  """
  @callback execute(command :: term(), state :: term()) :: {result :: term(), new_state :: term()}
end
