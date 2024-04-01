defmodule MinutemodemSimnet.Rig.Store do
  @moduledoc """
  eParl-backed store for rig attachments and assignments.
  """

  @key_prefix "simnet:rig:"

  @doc """
  Stores a rig attachment.
  """
  def put(rig_id, attachment) do
    case Eparl.propose({:put, key(rig_id), attachment}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets a rig attachment.
  """
  def get(rig_id) do
    case Eparl.propose({:get, key(rig_id)}) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Deletes a rig attachment.
  """
  def delete(rig_id) do
    case Eparl.propose({:delete, key(rig_id)}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Lists all rig attachments.
  """
  def list_all do
    case Eparl.propose({:keys, @key_prefix}) do
      {:ok, keys} ->
        keys
        |> Enum.map(fn k ->
          rig_id_str = String.replace_prefix(k, @key_prefix, "")

          case Eparl.propose({:get, k}) do
            {:ok, attachment} when not is_nil(attachment) ->
              # Use the rig_id from the attachment itself (preserves atom)
              {attachment.rig_id, attachment}
            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp key(rig_id) do
    "#{@key_prefix}#{rig_id}"
  end
end
