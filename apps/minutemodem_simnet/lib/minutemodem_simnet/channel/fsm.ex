defmodule MinutemodemSimnet.Channel.FSM do
  @moduledoc """
  GenStateMachine for a single directed channel (A→B).

  Owns one Rust WattersonChannel via NIF.
  Enforces Appendix E invariants locally.

  States:
  - :init       - Channel not yet instantiated in Rust
  - :armed      - Rust channel exists, waiting for first TX
  - :active     - Processing blocks, physics running
  - :draining   - Shutting down, flushing outstanding blocks
  - :terminated - Rust channel dropped, FSM stopping
  """
  use GenStateMachine, callback_mode: :state_functions

  require Logger

  alias MinutemodemSimnet.Channel.Registry
  alias MinutemodemSimnet.Channel.Params
  alias MinutemodemSimnet.Physics
  alias MinutemodemSimnet.Epoch
  alias MinutemodemSimnet.Routing.RxRegistry

  # Noise floor tick: 20ms at 9600 Hz = 192 samples
  @noise_tick_ms 20
  @noise_tick_samples 192
  @noise_block_bytes @noise_tick_samples * 4  # f32

  defstruct [
    :from_rig,
    :to_rig,
    :channel_id,
    :sample_index,
    :params,
    :rx_callback,
    :noise_timer
  ]



  def start_link({from_rig, to_rig, params}) do
    # Don't register via Horde.Registry - we cache pids in the Router instead
    # This avoids Horde registry propagation races
    GenStateMachine.start_link(
      __MODULE__,
      {from_rig, to_rig, params}
    )
  end

  def child_spec({from_rig, to_rig, params}) do
    %{
      id: {__MODULE__, from_rig, to_rig},
      start: {__MODULE__, :start_link, [{from_rig, to_rig, params}]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Process a TX block through the channel.
  """
  def process_tx(from_rig, to_rig, t0, samples) do
    GenStateMachine.call(Registry.via(from_rig, to_rig), {:tx_block, t0, samples})
  end

  @doc """
  Subscribe to RX blocks from this channel.
  """
  def subscribe_rx(from_rig, to_rig, callback) do
    GenStateMachine.call(Registry.via(from_rig, to_rig), {:subscribe_rx, callback})
  end

  # Callbacks

  @impl true
  def init({from_rig, to_rig, params}) do
    data = %__MODULE__{
      from_rig: from_rig,
      to_rig: to_rig,
      params: params,
      sample_index: 0
    }

    {:ok, :init, data, [{:next_event, :internal, :initialize}]}
  end

  # State: init

  def init(:internal, :initialize, data) do
    Logger.debug("[ChannelFSM] Initializing channel #{inspect(data.from_rig)} -> #{inspect(data.to_rig)}")

    case Epoch.Store.get_metadata() do
      {:ok, metadata} ->
        Logger.debug("[ChannelFSM] Got metadata: #{inspect(metadata)}")
        resolved_params = Params.resolve(data.params, metadata)
        Logger.debug("[ChannelFSM] Resolved params: #{inspect(resolved_params)}")

        case Physics.Channel.create(resolved_params, metadata.seed) do
          {:ok, channel_id} ->
            Logger.debug("[ChannelFSM] Created channel with id: #{inspect(channel_id)}")
            new_data = %{data | channel_id: channel_id, sample_index: metadata.t0}
            timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
            {:next_state, :armed, %{new_data | noise_timer: timer}}

          {:error, reason} ->
            Logger.error("[ChannelFSM] Failed to create channel: #{inspect(reason)}")
            {:stop, {:failed_to_create_channel, reason}}
        end

      :error ->
        Logger.error("[ChannelFSM] No active epoch")
        {:stop, :no_active_epoch}
    end
  end

  def init({:call, from}, _msg, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :initializing}}]}
  end

  # State: armed

  def armed({:call, from}, {:tx_block, t0, samples}, data) do
    # Cancel pending noise tick — real TX takes priority
    if data.noise_timer, do: Process.cancel_timer(data.noise_timer)

    case process_block(t0, samples, data) do
      {:ok, output, new_data} ->
        deliver_rx(output, new_data)
        timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
        {:next_state, :active, %{new_data | noise_timer: timer}, [{:reply, from, :ok}]}

      {:error, reason} ->
        timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
        {:keep_state, %{data | noise_timer: timer}, [{:reply, from, {:error, reason}}]}
    end
  end

  def armed({:call, from}, {:subscribe_rx, callback}, data) do
    new_data = %{data | rx_callback: callback}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def armed(:info, :noise_tick, data) do
    data = generate_noise_block(data)
    timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
    {:keep_state, %{data | noise_timer: timer}}
  end

  # State: active

  def active({:call, from}, {:tx_block, t0, samples}, data) do
    # Cancel pending noise tick — real TX takes priority
    if data.noise_timer, do: Process.cancel_timer(data.noise_timer)

    case process_block(t0, samples, data) do
      {:ok, output, new_data} ->
        deliver_rx(output, new_data)
        # Restart noise tick after TX block
        timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
        {:keep_state, %{new_data | noise_timer: timer}, [{:reply, from, :ok}]}

      {:error, reason} ->
        timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
        {:keep_state, %{data | noise_timer: timer}, [{:reply, from, {:error, reason}}]}
    end
  end

  def active({:call, from}, {:subscribe_rx, callback}, data) do
    new_data = %{data | rx_callback: callback}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def active(:info, :noise_tick, data) do
    data = generate_noise_block(data)
    timer = Process.send_after(self(), :noise_tick, @noise_tick_ms)
    {:keep_state, %{data | noise_timer: timer}}
  end

  def active(:cast, :drain, data) do
    if data.noise_timer, do: Process.cancel_timer(data.noise_timer)
    {:next_state, :draining, %{data | noise_timer: nil}}
  end

  # State: draining

  def draining({:call, from}, _msg, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining(:internal, :finish_drain, data) do
    if data.channel_id do
      Physics.Channel.destroy(data.channel_id)
    end

    {:next_state, :terminated, data}
  end

  # State: terminated

  def terminated({:call, from}, _msg, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :terminated}}]}
  end

  # Internal helpers

  # Generate a block of channel noise (zeros through the channel model → pure AWGN output)
  defp generate_noise_block(data) do
    silence = <<0::size(@noise_block_bytes)-unit(8)>>
    t0 = data.sample_index

    case do_process_block(t0, silence, data) do
      {:ok, output, new_data} ->
        deliver_rx(output, new_data)
        new_data

      {:error, _reason} ->
        data
    end
  end

  defp process_block(t0, samples, data) do
    # Handle time gaps by advancing the channel state
    # This maintains Appendix E compliance - fading evolves continuously
    gap = t0 - data.sample_index

    cond do
      gap > 0 ->
        # Time has passed - advance fading state before processing
        Physics.Channel.advance(data.channel_id, gap)
        do_process_block(t0, samples, data)

      gap == 0 ->
        # Continuous stream - process normally
        do_process_block(t0, samples, data)

      gap < 0 ->
        # Backwards = rig restarted, clock reset, etc. Just accept new timeline.
        Logger.info("[ChannelFSM] t0 went backwards: #{t0} < #{data.sample_index}, resetting timeline")
        reset_data = %{data | sample_index: t0}
        do_process_block(t0, samples, reset_data)
    end
  end

  defp do_process_block(t0, samples, data) do
    case Physics.Channel.process_block(data.channel_id, samples) do
      {:ok, output} ->
        n = byte_size(samples) |> div(4)
        new_data = %{data | sample_index: t0 + n}
        {:ok, output, new_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_rx(output, data) do
    delay_samples = Map.get(data.params, :delay_samples, 0)
    rx_t0 = data.sample_index + delay_samples
    freq_hz = Map.get(data.params, :freq_hz)

    # Build metadata for receiver
    metadata = %{
      regime: Map.get(data.params, :regime),
      snr_db: Map.get(data.params, :snr_db),
      distance_km: Map.get(data.params, :distance_km),
      doppler_bandwidth_hz: Map.get(data.params, :doppler_bandwidth_hz)
    }

    # Deliver via RxRegistry (clean API for core)
    RxRegistry.deliver(data.to_rig, data.from_rig, rx_t0, output, freq_hz, metadata)

    # Also call legacy callback if set (for testing/debugging)
    if data.rx_callback do
      data.rx_callback.({:rx_block, data.from_rig, data.to_rig, rx_t0, output})
    end
  end
end
