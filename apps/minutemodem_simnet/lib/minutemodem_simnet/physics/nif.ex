defmodule MinutemodemSimnet.Physics.Nif do
  @moduledoc """
  Rustler NIF module for Appendix E channel physics.

  This module provides the low-level interface to the Rust
  WattersonChannel implementation. Use `MinutemodemSimnet.Physics.Channel`
  for the higher-level Elixir API.
  """

  use Rustler,
    otp_app: :minutemodem_simnet,
    crate: :channel_physics

  @doc """
  Creates a new WattersonChannel and returns its slab handle.
  """
  @spec create_channel(map(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def create_channel(_params, _seed), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Processes a block of samples through the channel.

  Returns the channel-impaired output samples.
  """
  @spec process_block(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def process_block(_channel_id, _input_samples), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Advances the channel state without processing samples.

  Used for time synchronization.
  """
  @spec advance(non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def advance(_channel_id, _num_samples), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Destroys a channel and frees its slab slot.
  """
  @spec destroy_channel(non_neg_integer()) :: :ok | {:error, term()}
  def destroy_channel(_channel_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the current state of a channel for debugging/telemetry.
  """
  @spec get_state(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_state(_channel_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns the number of active channels in the slab.
  """
  @spec channel_count() :: non_neg_integer()
  def channel_count(), do: :erlang.nif_error(:nif_not_loaded)
end
