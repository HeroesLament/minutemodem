defmodule MinutemodemSimnet.Group.Store do
  @moduledoc """
  eParl-backed store for simulator group definitions.
  """

  alias MinutemodemSimnet.Group.Definition

  @key_prefix "simnet:group:"

  @doc """
  Creates a new simulator group.
  """
  def create_group(id, params) do
    group = Definition.new(id, params)

    case Eparl.propose({:put, key(id), group}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Updates an existing group.
  """
  def update_group(id, params) do
    case get(id) do
      {:ok, group} ->
        updated = struct(group, params)

        case Eparl.propose({:put, key(id), updated}) do
          {:ok, _} -> :ok
          error -> error
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a group.
  """
  def delete_group(id) do
    case Eparl.propose({:delete, key(id)}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets a group by ID.
  """
  def get(id) do
    case Eparl.propose({:get, key(id)}) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Lists all groups.
  """
  def list_groups do
    case Eparl.propose({:keys, @key_prefix}) do
      {:ok, keys} ->
        keys
        |> Enum.map(fn k ->
          case Eparl.propose({:get, k}) do
            {:ok, group} when not is_nil(group) -> group
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp key(id) do
    "#{@key_prefix}#{id}"
  end
end
