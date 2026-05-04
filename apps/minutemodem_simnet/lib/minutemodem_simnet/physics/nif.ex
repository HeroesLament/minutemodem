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

  # ===========================================================================
  # RxCombiner interface (ResourceArc-based)
  # ===========================================================================

  @doc """
  Creates a new RxCombiner. Returns an opaque NIF resource reference.
  """
  def combiner_new(_rig_id, _sample_rate, _block_samples, _noise_floor_dbm, _seed, _initial_rx_freq_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Adds an inbound Watterson channel to the combiner.
  """
  def combiner_add_channel(_ref, _from_rig, _params, _freq_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Removes an inbound channel from the combiner.
  """
  def combiner_remove_channel(_ref, _from_rig),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queues TX samples from a source rig for the next tick.
  Samples must be an f32-ne binary. Also updates the source's TX frequency.
  """
  def combiner_push_tx(_ref, _from_rig, _samples, _freq_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sets the frequency this receiver is tuned to.
  """
  def combiner_set_rx_freq(_ref, _freq_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Updates Watterson params for a specific inbound channel.
  Used when frequency changes alter propagation characteristics.
  """
  def combiner_update_channel_params(_ref, _from_rig, _params),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Processes one tick: runs all channels through Watterson, sums
  frequency-coherent outputs, adds noise floor.
  Returns combined f32-ne binary.
  """
  def combiner_tick(_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns the number of inbound channels in the combiner.
  """
  def combiner_channel_count(_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns debug info: list of {from_rig, tx_freq_hz, has_pending_tx}.
  """
  def combiner_info(_ref),
    do: :erlang.nif_error(:nif_not_loaded)
end
