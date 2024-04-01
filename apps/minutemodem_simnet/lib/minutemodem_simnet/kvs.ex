defmodule MinutemodemSimnet.KVS do
  @moduledoc """
  Simple KVS command module for eParl.
  """

  @behaviour Eparl.Data.Command

  @impl true
  def interferes?({op1, key1, _}, {op2, key2, _})
      when op1 in [:put, :delete] and op2 in [:put, :delete] do
    key1 == key2
  end

  def interferes?({:get, key1}, {op, key2, _}) when op in [:put, :delete] do
    key1 == key2
  end

  def interferes?({op, key1, _}, {:get, key2}) when op in [:put, :delete] do
    key1 == key2
  end

  def interferes?(_, _), do: false

  @impl true
  def execute({:put, key, value}, state) do
    {:ok, Map.put(state, key, value)}
  end

  def execute({:get, key}, state) do
    {Map.get(state, key), state}
  end

  def execute({:delete, key}, state) do
    {:ok, Map.delete(state, key)}
  end

  def execute({:keys, prefix}, state) do
    keys =
      state
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))

    {keys, state}
  end
end
