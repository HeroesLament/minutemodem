defmodule MinutemodemSimnet.Epoch.Store do
  @moduledoc """
  eParl-backed store for epoch metadata and contracts.

  Provides cluster-consistent storage for epoch facts that
  must survive node failures and relocations.
  """

  alias MinutemodemSimnet.Epoch.Metadata
  alias MinutemodemSimnet.Epoch.Contract

  @metadata_key "epoch:metadata"
  @contract_key "epoch:contract"

  @doc """
  Sets the current epoch metadata.
  """
  def set_metadata(%Metadata{} = metadata) do
    case Eparl.propose({:put, @metadata_key, metadata}) do
      {:ok, :ok} -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets the current epoch metadata.
  """
  def get_metadata do
    case Eparl.propose({:get, @metadata_key}) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Gets the current epoch metadata, raises if not found.
  """
  def get_metadata! do
    case get_metadata() do
      {:ok, metadata} -> metadata
      :error -> raise "No active epoch"
    end
  end

  @doc """
  Sets the current epoch contract.
  """
  def set_contract(%Contract{} = contract) do
    case Eparl.propose({:put, @contract_key, contract}) do
      {:ok, :ok} -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets the current epoch contract.
  """
  def get_contract do
    case Eparl.propose({:get, @contract_key}) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Gets the current epoch contract, raises if not found.
  """
  def get_contract! do
    case get_contract() do
      {:ok, contract} -> contract
      :error -> raise "No active epoch"
    end
  end

  @doc """
  Returns the current epoch if one exists.
  """
  def current_epoch do
    case get_metadata() do
      {:ok, metadata} ->
        case get_contract() do
          {:ok, contract} -> {:ok, %{metadata: metadata, contract: contract}}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  Clears all epoch data.
  """
  def clear do
    Eparl.propose({:delete, @metadata_key})
    Eparl.propose({:delete, @contract_key})
    :ok
  end
end
