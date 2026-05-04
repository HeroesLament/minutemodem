defmodule MinutemodemSimnet.RxCombiner.Combiner do
  @moduledoc """
  GenServer wrapping a Rust RxCombiner NIF resource.

  One per receiving rig. Owns all inbound Watterson channel instances
  via a single NIF ResourceArc. Ticks in response to the epoch
  TickDriver, producing one combined f32 audio block per tick.

  Lifecycle:
  - Created by Attachment.attach_rig
  - Channels added/removed as other rigs attach/detach
  - Destroyed by Attachment.detach_rig (or epoch stop)
  - ResourceArc GC'd → Rust Drop frees all Watterson channels
  """

  use GenServer
  require Logger

  alias MinutemodemSimnet.Physics.Nif
  alias MinutemodemSimnet.Physics.Types.ChannelParams
  alias MinutemodemSimnet.RxCombiner.Registry
  alias MinutemodemSimnet.Routing.RxRegistry

  defstruct [:rig_id, :ref, :sample_index, :block_samples, :rx_freq_hz, tx_queues: %{}, inbound_channels: MapSet.new()]

  # --- Public API ---

  def start_link({rig_id, opts}) do
    GenServer.start_link(__MODULE__, {rig_id, opts}, name: Registry.via(rig_id))
  end

  def child_spec({rig_id, opts}) do
    %{
      id: {__MODULE__, rig_id},
      start: {__MODULE__, :start_link, [{rig_id, opts}]},
      restart: :transient
    }
  end

  @doc """
  Adds an inbound Watterson channel from another rig.
  `params` should be a ChannelParams struct or compatible map.
  """
  def add_channel(rig_id, from_rig, params, freq_hz) do
    GenServer.call(Registry.via(rig_id), {:add_channel, from_rig, params, freq_hz})
  end

  @doc """
  Removes an inbound channel. Idempotent.
  """
  def remove_channel(rig_id, from_rig) do
    GenServer.call(Registry.via(rig_id), {:remove_channel, from_rig})
  end

  @doc """
  Queues TX samples from a source rig for the next tick.
  `samples` must be f32-ne binary.
  """
  def push_tx(rig_id, from_rig, samples, freq_hz) do
    GenServer.cast(Registry.via(rig_id), {:push_tx, from_rig, samples, freq_hz})
  end

  @doc """
  Sets the frequency this receiver is tuned to.
  Takes effect on the next tick.
  """
  def set_rx_frequency(rig_id, freq_hz) do
    GenServer.cast(Registry.via(rig_id), {:set_rx_freq, freq_hz})
  end

  @doc """
  Updates Watterson channel params for a specific inbound path.
  Used when frequency changes alter propagation characteristics.
  """
  def update_channel_params(rig_id, from_rig, params) do
    GenServer.call(Registry.via(rig_id), {:update_channel_params, from_rig, params})
  end

  @doc """
  Returns the number of inbound channels.
  """
  def channel_count(rig_id) do
    GenServer.call(Registry.via(rig_id), :channel_count)
  end

  @doc """
  Returns debug info about the combiner.
  """
  def info(rig_id) do
    GenServer.call(Registry.via(rig_id), :info)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({rig_id, opts}) do
    noise_floor_dbm = Keyword.get(opts, :noise_floor_dbm, -100.0)
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    block_samples = Keyword.get(opts, :block_samples, 192)
    seed = Keyword.get(opts, :seed, :erlang.unique_integer([:positive]))
    t0 = Keyword.get(opts, :t0, 0)
    rx_freq_hz = Keyword.get(opts, :rx_freq_hz, 7_300_000)

    # Create the NIF resource — this is the Rust RxCombiner behind a ResourceArc
    ref = Nif.combiner_new(
      to_string(rig_id),
      sample_rate,
      block_samples,
      noise_floor_dbm,
      seed,
      rx_freq_hz
    )

    # Join the tick subscriber group
    :pg.join(:simnet_pg, :tick_subscribers, self())

    Logger.info("[RxCombiner] Started for rig #{short(rig_id)} @ #{rx_freq_hz} Hz")

    {:ok, %__MODULE__{
      rig_id: rig_id,
      ref: ref,
      sample_index: t0,
      block_samples: block_samples,
      rx_freq_hz: rx_freq_hz
    }}
  end

  @impl true
  def handle_call({:add_channel, from_rig, params, freq_hz}, _from, state) do
    nif_params = to_nif_params(params)
    result = Nif.combiner_add_channel(state.ref, to_string(from_rig), nif_params, freq_hz)
    Logger.debug("[RxCombiner #{short(state.rig_id)}] Added channel from #{short(from_rig)} @ #{freq_hz} Hz")
    {:reply, result, %{state | inbound_channels: MapSet.put(state.inbound_channels, from_rig)}}
  end

  @impl true
  def handle_call({:remove_channel, from_rig}, _from, state) do
    result = Nif.combiner_remove_channel(state.ref, to_string(from_rig))
    Logger.debug("[RxCombiner #{short(state.rig_id)}] Removed channel from #{short(from_rig)}: #{result}")
    {:reply, result, %{state | inbound_channels: MapSet.delete(state.inbound_channels, from_rig)}}
  end

  @impl true
  def handle_call({:update_channel_params, from_rig, params}, _from, state) do
    nif_params = to_nif_params(params)
    result = Nif.combiner_update_channel_params(state.ref, to_string(from_rig), nif_params)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:channel_count, _from, state) do
    {:reply, Nif.combiner_channel_count(state.ref), state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      rig_id: state.rig_id,
      rx_freq_hz: state.rx_freq_hz,
      sample_index: state.sample_index,
      channel_count: Nif.combiner_channel_count(state.ref),
      channels: Nif.combiner_info(state.ref)
    }
    {:reply, info, state}
  end

  @impl true
  def handle_cast({:push_tx, from_rig, samples, freq_hz}, state) do
    # The Rust NIF combiner only processes the first block_samples of each push_tx
    # and discards the rest. To handle TX frames larger than one block (e.g., a
    # 4224-sample Fast WALE frame at 192 samples/block), we buffer the TX samples
    # in Elixir and push one block per tick.
    #
    # Enqueue the samples after any already-queued samples for this source rig.
    block_bytes = state.block_samples * 4  # f32 = 4 bytes
    incoming_samples = div(byte_size(samples), 4)
    incoming_blocks = Float.ceil(incoming_samples / state.block_samples) |> round()
    Logger.info("[RxCombiner #{short(state.rig_id)}] push_tx from #{short(from_rig)}: #{incoming_samples} samples (#{incoming_blocks} blocks) @ #{freq_hz} Hz")

    existing = Map.get(state.tx_queues, from_rig, {<<>>, freq_hz})
    {existing_buf, _old_freq} = existing
    new_buf = existing_buf <> samples

    # Push the first block immediately if we have enough
    if byte_size(new_buf) >= block_bytes do
      <<chunk::binary-size(block_bytes), rest::binary>> = new_buf
      Nif.combiner_push_tx(state.ref, to_string(from_rig), chunk, freq_hz)
      new_queues = if byte_size(rest) > 0 do
        Map.put(state.tx_queues, from_rig, {rest, freq_hz})
      else
        Map.delete(state.tx_queues, from_rig)
      end
      {:noreply, %{state | tx_queues: new_queues}}
    else
      # Not enough for a full block yet — just buffer
      {:noreply, %{state | tx_queues: Map.put(state.tx_queues, from_rig, {new_buf, freq_hz})}}
    end
  end

  @impl true
  def handle_cast({:set_rx_freq, freq_hz}, state) do
    old_freq = state.rx_freq_hz
    Nif.combiner_set_rx_freq(state.ref, freq_hz)

    # Recompute Watterson channel params if frequency actually changed
    if freq_hz != old_freq and MapSet.size(state.inbound_channels) > 0 do
      recompute_channel_params(state, freq_hz)
    end

    {:noreply, %{state | rx_freq_hz: freq_hz}}
  end

  # Tick from TickDriver — drain TX queues, process all channels, deliver combined output
  @impl true
  def handle_info({:epoch_tick, sample_index}, state) do
    # Drain one block from each source rig's TX queue into the NIF
    block_bytes = state.block_samples * 4  # f32 = 4 bytes

    new_queues = Enum.reduce(state.tx_queues, %{}, fn {from_rig, {buf, freq_hz}}, acc ->
      if byte_size(buf) >= block_bytes do
        <<chunk::binary-size(block_bytes), rest::binary>> = buf
        Nif.combiner_push_tx(state.ref, to_string(from_rig), chunk, freq_hz)
        if byte_size(rest) > 0 do
          Map.put(acc, from_rig, {rest, freq_hz})
        else
          acc
        end
      else
        # Remaining samples less than a full block — push what we have
        # (the NIF will pad with silence or process partial)
        if byte_size(buf) > 0 do
          # Pad to full block size
          padding_bytes = block_bytes - byte_size(buf)
          padded = buf <> :binary.copy(<<0, 0, 0, 0>>, div(padding_bytes, 4))
          Nif.combiner_push_tx(state.ref, to_string(from_rig), padded, freq_hz)
        end
        acc
      end
    end)

    # Log only when there's active TX traffic (queue was non-empty or still has data)
    if state.tx_queues != %{} or new_queues != %{} do
      remaining_blocks = Enum.map(new_queues, fn {rig, {buf, _}} -> {short(rig), div(byte_size(buf), block_bytes)} end)
      Logger.info("[RxCombiner #{short(state.rig_id)}] tick: drained #{map_size(state.tx_queues)} source(s), remaining=#{inspect(remaining_blocks)}")
    end

    # One NIF call: process all channels, sum coherent outputs, add noise
    combined = Nif.combiner_tick(state.ref)

    # Deliver to RxRegistry subscriber (SimnetBridge on core)
    metadata = %{
      combined: true,
      rx_freq_hz: state.rx_freq_hz,
      channel_count: Nif.combiner_channel_count(state.ref)
    }

    RxRegistry.deliver(
      state.rig_id,
      :combined,
      sample_index,
      combined,
      state.rx_freq_hz,
      metadata
    )

    {:noreply, %{state | sample_index: sample_index + state.block_samples, tx_queues: new_queues}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[RxCombiner #{short(state.rig_id)}] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    :pg.leave(:simnet_pg, :tick_subscribers, self())
    Logger.info("[RxCombiner] Stopped for rig #{short(state.rig_id)}: #{inspect(reason)}")
    # ref becomes unreferenced → BEAM GC → Rust Drop → all Watterson channels freed
    :ok
  end

  # --- Internal ---

  defp to_nif_params(%ChannelParams{} = params), do: params

  defp to_nif_params(params) when is_map(params) do
    sample_rate = Map.get(params, :sample_rate, 9600)

    delay_spread_samples =
      case Map.get(params, :delay_spread_samples) do
        nil ->
          delay_ms = Map.get(params, :delay_spread_ms, 0)
          round(delay_ms * sample_rate / 1000)
        samples ->
          samples
      end

    %ChannelParams{
      sample_rate: sample_rate,
      delay_spread_samples: delay_spread_samples,
      doppler_bandwidth_hz: Map.get(params, :doppler_bandwidth_hz, 1.0),
      snr_db: Map.get(params, :snr_db, 10.0),
      carrier_freq_hz: Map.get(params, :carrier_freq_hz, 1800.0)
    }
  end

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(id), do: inspect(id)

  # Recompute Watterson channel parameters for all inbound channels at a new frequency.
  # Called when the receiver hops to a different frequency (e.g., ALE scan).
  defp recompute_channel_params(state, freq_hz) do
    alias MinutemodemSimnet.HFEngine

    for from_rig <- state.inbound_channels do
      case HFEngine.compute(from_rig, state.rig_id, freq_hz) do
        {:ok, params} ->
          nif_params = to_nif_params(params)
          Nif.combiner_update_channel_params(state.ref, to_string(from_rig), nif_params)

        {:error, reason} ->
          Logger.warning("[RxCombiner #{short(state.rig_id)}] Failed to recompute channel from #{short(from_rig)} @ #{freq_hz} Hz: #{inspect(reason)}")
      end
    end
  end
end
