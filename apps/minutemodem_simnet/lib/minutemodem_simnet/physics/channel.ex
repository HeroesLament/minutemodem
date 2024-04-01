defmodule MinutemodemSimnet.Physics.Channel do
  @moduledoc """
  High-level Elixir interface to the Rust WattersonChannel.

  Wraps the NIF calls with proper type conversion and
  error handling.
  """

  alias MinutemodemSimnet.Physics.Nif
  alias MinutemodemSimnet.Physics.Types.ChannelParams

  @doc """
  Creates a new Watterson channel with the given parameters.

  Returns the channel ID (slab handle) on success.
  """
  @spec create(map() | ChannelParams.t(), integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create(%ChannelParams{} = params, seed) do
    # NIF expects the struct directly
    nif_params = %MinutemodemSimnet.Physics.Types.ChannelParams{
      sample_rate: params.sample_rate,
      delay_spread_samples: params.delay_spread_samples,
      doppler_bandwidth_hz: params.doppler_bandwidth_hz,
      snr_db: params.snr_db,
      carrier_freq_hz: params.carrier_freq_hz || 1800.0
    }

    Nif.create_channel(nif_params, seed)
  end

  def create(%MinutemodemSimnet.Channel.Params{} = params, seed) do
    # Convert from Channel.Params (has delay_spread_ms) to NIF params (has delay_spread_samples)
    delay_spread_samples =
      round((params.delay_spread_ms || 0) * (params.sample_rate || 9600) / 1000)

    nif_params = %MinutemodemSimnet.Physics.Types.ChannelParams{
      sample_rate: params.sample_rate || 9600,
      delay_spread_samples: delay_spread_samples,
      doppler_bandwidth_hz: params.doppler_bandwidth_hz || 1.0,
      snr_db: params.snr_db || 10.0,
      carrier_freq_hz: params.carrier_freq_hz || 1800.0
    }

    Nif.create_channel(nif_params, seed)
  end

  def create(params, seed) when is_map(params) do
    # Convert plain map to proper struct for NIF
    # Handles both delay_spread_ms and delay_spread_samples
    sample_rate = Map.get(params, :sample_rate, 9600)

    delay_spread_samples =
      case Map.get(params, :delay_spread_samples) do
        nil ->
          delay_ms = Map.get(params, :delay_spread_ms, 0)
          round(delay_ms * sample_rate / 1000)

        samples ->
          samples
      end

    nif_params = %MinutemodemSimnet.Physics.Types.ChannelParams{
      sample_rate: sample_rate,
      delay_spread_samples: delay_spread_samples,
      doppler_bandwidth_hz: Map.get(params, :doppler_bandwidth_hz, 1.0),
      snr_db: Map.get(params, :snr_db, 10.0),
      carrier_freq_hz: Map.get(params, :carrier_freq_hz, 1800.0)
    }

    Nif.create_channel(nif_params, seed)
  end

  @doc """
  Processes a block of input samples through the channel.

  Applies two-path Watterson fading, delay, and noise.
  Returns the impaired output samples as a binary of f32 values.

  Input and output are native-endian f32 binaries.
  """
  @spec process_block(non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def process_block(channel_id, input_samples) when is_binary(input_samples) do
    # NIF returns Binary directly via Env pattern (zero-copy)
    Nif.process_block(channel_id, input_samples)
  end

  @doc """
  Advances channel state by N samples without processing.

  Used when a channel needs to stay synchronized with
  simulation time but isn't receiving TX blocks.
  """
  @spec advance(non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def advance(channel_id, num_samples) do
    Nif.advance(channel_id, num_samples)
  end

  @doc """
  Destroys a channel and frees its resources.
  """
  @spec destroy(non_neg_integer()) :: :ok | {:error, term()}
  def destroy(channel_id) do
    Nif.destroy_channel(channel_id)
  end

  @doc """
  Gets the current channel state for debugging.
  """
  @spec get_state(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_state(channel_id) do
    Nif.get_state(channel_id)
  end

  @doc """
  Returns the number of active channels.
  """
  @spec count() :: non_neg_integer()
  def count do
    Nif.channel_count()
  end
end
