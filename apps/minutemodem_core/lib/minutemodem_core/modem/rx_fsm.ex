defmodule MinuteModemCore.Modem.RxFSM do
  @moduledoc """
  Receiver finite state machine.

  Wraps `Modem110D.Rx` (the functional PHY-level receiver) and exposes
  DTE-level states per MIL-STD-188-110D Appendix A Figure A-10.

  ## DTE States (what interfaces see)

  - `:no_carrier` - Sync-acquire phase, searching for preamble
  - `:carrier_detected` - Preamble locked, WID decoded
  - `:receiving` - Actively receiving and delivering data

  ## PHY States (internal, from Modem110D.Rx)

  - `:idle` / `:searching` → DTE `:no_carrier`
  - `:tlc_found` / `:preamble` → DTE `:carrier_detected`
  - `:receiving` → DTE `:receiving`
  - `:complete` → DTE `:no_carrier`

  ## Data Flow

      Rig.Audio (pubsub)
           │
           │ {:rx_audio, rig_id, samples}
           ▼
       RxFSM (this module)
           │
           │ Modem110D.Rx.process(rx, samples)
           ▼
       Modem110D.Rx events
           │
           │ {:wid_decoded, wid}
           │ {:data, symbols}
           │ {:complete, stats}
           ▼
       Events.broadcast → Interface adapters
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias MinuteModemCore.Modem.{Events, Arbiter}
  alias MinuteModemCore.Modem110D.Rx, as: PhyRx
  alias MinuteModemCore.Modem110D.{Tables, WID, Codec}
  alias MinuteModemCore.Modem110D.FEC.Interleaver
  alias MinuteModemCore.Rig.Audio, as: RigAudio
  alias MinuteModemCore.DSP.PhyModem

  # Timeout for auto-flush when no new data arrives while receiving (in ms)
  @rx_idle_timeout 500

  # ============================================================================
  # State Data
  # ============================================================================

  defstruct [
    :rig_id,
    :bw_khz,
    :sample_rate,
    # PHY receiver (Modem110D.Rx struct)
    :phy_rx,
    # Unified demodulator for baseband IQ extraction
    :demod,
    # Decoded waveform parameters (from WID)
    :wid,
    :data_rate,
    :blocking_factor,
    # FEC decoder (Codec.Decoder struct)
    :codec_decoder,
    # Data stream tracking
    :packet_count,
    :total_bytes,
    # Symbol buffer for assembly into packets
    :symbol_buffer,
    # Progress tracking
    :block_size_symbols,
    :frames_in_block,
    :frame_counter
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    GenStateMachine.start_link(
      __MODULE__,
      opts,
      name: via(rig_id)
    )
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :rx}}}
  end

  @doc "Feed audio samples (I/Q) to the receiver"
  def process_samples(server, samples) do
    GenStateMachine.cast(server, {:samples, samples})
  end

  @doc "Abort current reception"
  def abort(server) do
    GenStateMachine.cast(server, :abort)
  end

  @doc "Flush accumulated codec data (call when transmission ends)"
  def flush_codec(server) do
    GenStateMachine.cast(server, :flush_codec)
  end

  @doc "Get current status"
  def status(server) do
    GenStateMachine.call(server, :status)
  end

  @doc "Start the receiver (begin searching for signal)"
  def start_rx(server) do
    GenStateMachine.cast(server, :start_rx)
  end

  @doc "Stop the receiver"
  def stop_rx(server) do
    GenStateMachine.cast(server, :stop_rx)
  end

  # ============================================================================
  # Initialization
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    bw_khz = Keyword.get(opts, :bw_khz, 3)
    sample_rate = Keyword.get(opts, :sample_rate, 9600)

    # Set rig identifier for all log messages from this process
    Logger.metadata(rig: String.slice(rig_id, 0, 8))

    # Create PHY receiver
    phy_rx = PhyRx.new(bw_khz, sample_rate: sample_rate)

    # Create unified demodulator for baseband IQ extraction
    # Starts with PSK8 for preamble detection; constellation switches happen in PhyRx
    demod = PhyModem.unified_demod_new(:psk8, sample_rate)

    data = %__MODULE__{
      rig_id: rig_id,
      bw_khz: bw_khz,
      sample_rate: sample_rate,
      phy_rx: phy_rx,
      demod: demod,
      wid: nil,
      data_rate: 0,
      blocking_factor: 0,
      codec_decoder: nil,
      packet_count: 0,
      total_bytes: 0,
      symbol_buffer: [],
      block_size_symbols: 0,
      frames_in_block: 0,
      frame_counter: 0
    }

    # Subscribe to RX audio from Rig.Audio pubsub
    RigAudio.subscribe(rig_id)

    Logger.info("[Modem.RxFSM] Started for rig #{rig_id}, bw=#{bw_khz}kHz")

    {:ok, :no_carrier, data}
  end

  # ============================================================================
  # State: no_carrier
  # ============================================================================

  def no_carrier(:enter, old_state, data) do
    Logger.debug("[Modem.RxFSM] Entering :no_carrier from #{inspect(old_state)}, PhyRx state: #{data.phy_rx.state}")

    # Reset tracking but keep PHY searching (full-duplex always listens)
    {phy_rx, _events} = PhyRx.start(data.phy_rx)

    Logger.debug("[Modem.RxFSM] After PhyRx.start, PhyRx state: #{phy_rx.state}")

    # Reset demodulator for clean acquisition on next transmission
    PhyModem.unified_demod_reset(data.demod)

    new_data = %{data |
      phy_rx: phy_rx,
      wid: nil,
      data_rate: 0,
      blocking_factor: 0,
      codec_decoder: nil,
      packet_count: 0,
      total_bytes: 0,
      symbol_buffer: [],
      block_size_symbols: 0,
      frames_in_block: 0,
      frame_counter: 0
    }

    emit_carrier_status(new_data, :no_carrier)
    Arbiter.rx_idle(via_arbiter(data.rig_id))

    {:keep_state, new_data}
  end

  def no_carrier({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :no_carrier)}]}
  end

  def no_carrier(:cast, :start_rx, data) do
    # Start PHY receiver searching
    {phy_rx, _events} = PhyRx.start(data.phy_rx)
    {:keep_state, %{data | phy_rx: phy_rx}}
  end

  def no_carrier(:cast, {:samples, samples}, data) do
    process_samples_internal(samples, data, :no_carrier)
  end

  def no_carrier(:cast, :abort, _data) do
    :keep_state_and_data
  end

  def no_carrier(:cast, :stop_rx, data) do
    {phy_rx, _events} = PhyRx.stop(data.phy_rx)
    {:keep_state, %{data | phy_rx: phy_rx}}
  end

  # Handle RX audio from Rig.Audio pubsub (basic form)
  def no_carrier(:info, {:rx_audio, _rig_id, samples}, data) do
    Logger.debug("[Modem.RxFSM] no_carrier got #{length(samples)} samples, PhyRx state: #{data.phy_rx.state}")
    process_samples_internal(samples, data, :no_carrier)
  end

  # Handle RX audio with metadata (from simnet)
  def no_carrier(:info, {:rx_audio, _rig_id, samples, _metadata}, data) do
    Logger.debug("[Modem.RxFSM] no_carrier got #{length(samples)} samples (with metadata), PhyRx state: #{data.phy_rx.state}")
    process_samples_internal(samples, data, :no_carrier)
  end

  # Ignore DOWN messages from monitored processes
  def no_carrier(:info, {:DOWN, _, _, _, _}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: carrier_detected (preamble synced, WID decoded)
  # ============================================================================

  def carrier_detected(:enter, _old_state, data) do
    emit_carrier_status(data, :carrier_detected)
    Arbiter.rx_active(via_arbiter(data.rig_id))
    :keep_state_and_data
  end

  def carrier_detected({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :carrier_detected)}]}
  end

  def carrier_detected(:cast, {:samples, samples}, data) do
    process_samples_internal(samples, data, :carrier_detected)
  end

  def carrier_detected(:cast, :abort, data) do
    emit_rx_data(data.rig_id, <<>>, :last)
    {:next_state, :no_carrier, data}
  end

  def carrier_detected(:cast, :stop_rx, data) do
    {:next_state, :no_carrier, data}
  end

  def carrier_detected(:cast, :flush_codec, data) do
    # Flush accumulated soft bits (in case we're waiting for more data)
    case data.codec_decoder do
      nil ->
        :keep_state_and_data
      decoder ->
        {new_decoder, events} = Codec.flush(decoder)
        decoded_bits = extract_data_bits(events)

        if decoded_bits != [] do
          packet = bits_to_bytes(decoded_bits)
          Logger.info("[Modem.RxFSM] Flush: decoded #{byte_size(packet)} bytes")
          emit_rx_data(data.rig_id, packet, :continuation)
          {:keep_state, %{data | codec_decoder: new_decoder, total_bytes: data.total_bytes + byte_size(packet)}}
        else
          {:keep_state, %{data | codec_decoder: new_decoder}}
        end
    end
  end

  # Handle RX audio from Rig.Audio pubsub
  def carrier_detected(:info, {:rx_audio, _rig_id, samples}, data) do
    process_samples_internal(samples, data, :carrier_detected)
  end

  def carrier_detected(:info, {:rx_audio, _rig_id, samples, _metadata}, data) do
    process_samples_internal(samples, data, :carrier_detected)
  end

  def carrier_detected(:info, {:DOWN, _, _, _, _}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: receiving
  # ============================================================================

  def receiving(:enter, _old_state, data) do
    emit_carrier_status(data, :receiving)
    # Set initial timeout - will be reset on each data reception
    {:keep_state_and_data, [{:state_timeout, @rx_idle_timeout, :idle_timeout}]}
  end

  def receiving({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :receiving)}]}
  end

  def receiving(:cast, {:samples, samples}, data) do
    # Process samples and reset timeout
    case process_samples_internal(samples, data, :receiving) do
      {:keep_state, new_data} ->
        {:keep_state, new_data, [{:state_timeout, @rx_idle_timeout, :idle_timeout}]}
      {:next_state, next_state, new_data} ->
        {:next_state, next_state, new_data}
    end
  end

  def receiving(:state_timeout, :idle_timeout, data) do
    # No new data for @rx_idle_timeout ms - flush and emit what we have
    Logger.info("[Modem.RxFSM] Idle timeout - flushing codec")

    case data.codec_decoder do
      nil ->
        {:next_state, :no_carrier, data}
      decoder ->
        {_decoder, events} = Codec.flush(decoder)
        decoded_bits = extract_data_bits(events)

        if decoded_bits != [] do
          packet = bits_to_bytes(decoded_bits)
          Logger.info("[Modem.RxFSM] Timeout flush: decoded #{byte_size(packet)} bytes")
          emit_rx_data(data.rig_id, packet, :last)
        else
          emit_rx_data(data.rig_id, <<>>, :last)
        end

        Events.broadcast(data.rig_id, {:modem, {:rx_complete, %{timeout: true}}})
        {:next_state, :no_carrier, %{data | codec_decoder: nil}}
    end
  end

  def receiving(:cast, :abort, data) do
    # Flush any remaining PHY data
    {phy_rx, flush_events} = PhyRx.flush(data.phy_rx)
    data = %{data | phy_rx: phy_rx}

    # Process flush events (may include final symbols)
    {data, _} = process_phy_events_for_data(flush_events, data)

    # Flush accumulated soft bits through Viterbi decoder
    final_packet = case data.codec_decoder do
      nil -> <<>>
      decoder ->
        {_decoder, events} = Codec.flush(decoder)
        decoded_bits = extract_data_bits(events)
        if decoded_bits != [], do: bits_to_bytes(decoded_bits), else: <<>>
    end

    if byte_size(final_packet) > 0 do
      Logger.info("[Modem.RxFSM] Abort flush: decoded #{byte_size(final_packet)} bytes")
      emit_rx_data(data.rig_id, final_packet, :continuation)
    end

    # Emit LAST and transition
    emit_rx_data(data.rig_id, <<>>, :last)
    {:next_state, :no_carrier, %{data | codec_decoder: nil}}
  end

  def receiving(:cast, :stop_rx, data) do
    {:next_state, :no_carrier, data}
  end

  def receiving(:cast, :flush_codec, data) do
    # Flush accumulated soft bits through Viterbi decoder
    case data.codec_decoder do
      nil ->
        :keep_state_and_data
      decoder ->
        {new_decoder, events} = Codec.flush(decoder)
        decoded_bits = extract_data_bits(events)

        if decoded_bits != [] do
          packet = bits_to_bytes(decoded_bits)
          Logger.info("[Modem.RxFSM] Flush: decoded #{byte_size(packet)} bytes")
          new_data = %{data |
            codec_decoder: new_decoder,
            total_bytes: data.total_bytes + byte_size(packet)
          }
          emit_rx_data(data.rig_id, packet, :continuation)
          {:keep_state, new_data}
        else
          {:keep_state, %{data | codec_decoder: new_decoder}}
        end
    end
  end

  # Handle RX audio from Rig.Audio pubsub
  def receiving(:info, {:rx_audio, _rig_id, samples}, data) do
    case process_samples_internal(samples, data, :receiving) do
      {:keep_state, new_data} ->
        {:keep_state, new_data, [{:state_timeout, @rx_idle_timeout, :idle_timeout}]}
      {:next_state, next_state, new_data} ->
        Logger.debug("[Modem.RxFSM] Transitioning from :receiving to #{inspect(next_state)}")
        {:next_state, next_state, new_data}
    end
  end

  def receiving(:info, {:rx_audio, _rig_id, samples, _metadata}, data) do
    case process_samples_internal(samples, data, :receiving) do
      {:keep_state, new_data} ->
        {:keep_state, new_data, [{:state_timeout, @rx_idle_timeout, :idle_timeout}]}
      {:next_state, next_state, new_data} ->
        Logger.debug("[Modem.RxFSM] Transitioning from :receiving to #{inspect(next_state)} (with metadata)")
        {:next_state, next_state, new_data}
    end
  end

  def receiving(:info, {:DOWN, _, _, _, _}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # Common Sample Processing
  # ============================================================================

  defp process_samples_internal(samples, data, current_state) do
    # For large sample batches (new transmission), reset demod for clean PLL acquisition
    if length(samples) > 1000 do
      PhyModem.unified_demod_reset(data.demod)
    end

    # Demodulate to baseband IQ using unified demodulator
    # This handles carrier mixing, matched filtering, and symbol timing recovery
    iq_samples = PhyModem.unified_demod_iq(data.demod, samples)

    # Feed IQ samples to PHY receiver
    # PhyRx handles sync detection, preamble decode, and constellation switching
    {phy_rx, events} = PhyRx.process(data.phy_rx, iq_samples)
    data = %{data | phy_rx: phy_rx}

    # Check for state transitions based on PHY events
    handle_phy_events(events, data, current_state)
  end

  # ============================================================================
  # PHY Event Handling
  # ============================================================================

  defp handle_phy_events(events, data, current_state) do
    # Process events and determine state transitions
    {data, transition} = Enum.reduce(events, {data, nil}, fn event, {d, trans} ->
      {new_d, new_trans} = handle_phy_event(event, d, current_state)
      # Keep first transition
      {new_d, trans || new_trans}
    end)

    case transition do
      nil -> {:keep_state, data}
      new_state -> {:next_state, new_state, data}
    end
  end

  defp handle_phy_event({:sync_acquired, info}, data, :no_carrier) do
    Logger.debug("[Modem.RxFSM] Sync acquired: #{inspect(info)}")
    {data, nil}  # Wait for WID
  end

  defp handle_phy_event({:wid_decoded, wid}, data, _state) do
    Logger.info("[Modem.RxFSM] WID decoded: waveform=#{wid.waveform}, interleaver=#{wid.interleaver}, K=#{wid.constraint_length}")

    # Extract rate/blocking from WID
    data_rate = calculate_data_rate(wid, data.bw_khz)
    blocking_factor = calculate_blocking_factor(wid, data.bw_khz)

    # Calculate block size for progress tracking
    block_size_bits = Interleaver.block_size(wid.waveform, wid.interleaver, data.bw_khz)
    bits_per_symbol = Tables.bits_per_symbol(Tables.modulation(wid.waveform))
    block_size_symbols = div(block_size_bits, bits_per_symbol)
    frames_in_block = div(block_size_symbols, 48)  # 48 symbols per frame for WID 1

    Logger.info("[Modem.RxFSM] Block: #{block_size_symbols} symbols = #{frames_in_block} frames")

    # Initialize FEC decoder
    {:ok, codec_decoder} = Codec.decoder_new(wid, bandwidth: data.bw_khz)

    new_data = %{data |
      wid: wid,
      data_rate: data_rate,
      blocking_factor: blocking_factor,
      codec_decoder: codec_decoder,
      block_size_symbols: block_size_symbols,
      frames_in_block: frames_in_block,
      frame_counter: 0
    }

    # Process any symbols that were buffered before WID was decoded
    new_data = if new_data.symbol_buffer != [] do
      Logger.debug("[Modem.RxFSM] Processing #{length(new_data.symbol_buffer)} buffered symbols after WID decode")
      {updated_data, packet} = accumulate_symbols(%{new_data | symbol_buffer: []}, new_data.symbol_buffer)

      if packet do
        Logger.info("[Modem.RxFSM] Emitting rx_data packet from buffer: #{byte_size(packet)} bytes")
        emit_rx_data(data.rig_id, packet, :continuation)
      end

      updated_data
    else
      new_data
    end

    # Emit WID event for interface
    Events.broadcast(data.rig_id, {:modem, {:wid_decoded, wid}})

    {new_data, :carrier_detected}
  end

  defp handle_phy_event({:data_start, _wid}, data, _state) do
    Logger.debug("[Modem.RxFSM] Data start")
    {data, :receiving}
  end

  defp handle_phy_event({:data, symbols}, data, _state) do
    # Accumulate symbols and emit as data packets
    {data, packet} = accumulate_symbols(data, symbols)

    if packet do
      Logger.info("[Modem.RxFSM] Decoded #{byte_size(packet)} bytes (total: #{data.total_bytes} bytes)")
      emit_rx_data(data.rig_id, packet, :continuation)
    end

    {data, nil}
  end

  defp handle_phy_event({:complete, stats}, data, _state) do
    Logger.info("[Modem.RxFSM] Reception complete: #{inspect(stats)}")

    # Flush accumulated soft bits through Viterbi decoder
    final_packet = case data.codec_decoder do
      nil -> <<>>
      decoder ->
        # Flush all accumulated soft bits at once for proper tail-biting decode
        {_decoder, events} = Codec.flush(decoder)
        decoded_bits = extract_data_bits(events)
        if decoded_bits != [], do: bits_to_bytes(decoded_bits), else: <<>>
    end

    emit_rx_data(data.rig_id, final_packet, :last)
    Events.broadcast(data.rig_id, {:modem, {:rx_complete, stats}})

    # CRITICAL: Reset PhyRx here, not in :enter callback!
    # When all samples arrive in one batch, the FSM may already be in :no_carrier,
    # so {:next_state, :no_carrier, _} won't trigger the :enter callback.
    {phy_rx, _events} = PhyRx.start(data.phy_rx)
    Logger.debug("[Modem.RxFSM] After reception complete, reset PhyRx: #{data.phy_rx.state} → #{phy_rx.state}")

    {%{data | symbol_buffer: [], codec_decoder: nil, phy_rx: phy_rx}, :no_carrier}
  end

  defp handle_phy_event({:eot_detected, info}, data, _state) do
    Logger.debug("[Modem.RxFSM] EOT detected: #{inspect(info)}")
    {data, nil}  # Will get :complete next
  end

  defp handle_phy_event({:channel_estimate, _est}, data, _state) do
    # Could emit for debugging/monitoring
    {data, nil}
  end

  defp handle_phy_event({:error, reason}, data, _state) do
    Logger.warning("[Modem.RxFSM] PHY error: #{inspect(reason)}")
    {data, nil}
  end

  defp handle_phy_event(_event, data, _state) do
    {data, nil}
  end

  defp process_phy_events_for_data(events, data) do
    Enum.reduce(events, {data, []}, fn
      {:data, symbols}, {d, packets} ->
        {new_d, packet} = accumulate_symbols(d, symbols)
        if packet, do: {new_d, [packet | packets]}, else: {new_d, packets}

      _, acc ->
        acc
    end)
  end

  # ============================================================================
  # Symbol/Data Conversion with FEC Decoding (via Codec)
  # ============================================================================

  # Process symbols through the FEC decoder and emit decoded data
  # Returns {updated_data, packet_binary | nil}
  defp accumulate_symbols(data, new_symbols) do
    case data.codec_decoder do
      nil ->
        # No codec decoder yet (WID not decoded) - buffer raw symbols
        Logger.warning("[Modem.RxFSM] No codec decoder, buffering #{length(new_symbols)} symbols")
        {%{data | symbol_buffer: data.symbol_buffer ++ new_symbols}, nil}

      decoder ->
        # Increment frame counter for progress display
        new_frame_counter = data.frame_counter + 1

        # Show progress: frame X/Y
        if data.frames_in_block > 0 do
          frame_in_block = rem(new_frame_counter - 1, data.frames_in_block) + 1
          Logger.debug("[Modem.RxFSM] Frame #{frame_in_block}/#{data.frames_in_block}")
        end

        # Pass symbols through Codec.decode (accumulates soft bits, doesn't decode yet)
        {new_decoder, events} = Codec.decode(decoder, new_symbols)

        # Log accumulation progress
        accumulated = Codec.accumulated_bits(new_decoder)
        if rem(new_frame_counter, data.frames_in_block) == 0 do
          Logger.debug("[Modem.RxFSM] Block complete, accumulated #{accumulated} soft bits")
        end

        # Extract decoded data bits from events
        decoded_bits = extract_data_bits(events)

        if decoded_bits != [] do
          packet = bits_to_bytes(decoded_bits)

          # Check for EOM
          eom_detected = Enum.any?(events, fn
            {:eom_detected, _} -> true
            _ -> false
          end)

          if eom_detected do
            Logger.info("[Modem.RxFSM] EOM detected")
          end

          new_data = %{data |
            codec_decoder: new_decoder,
            packet_count: data.packet_count + 1,
            total_bytes: data.total_bytes + byte_size(packet),
            frame_counter: new_frame_counter
          }

          {new_data, packet}
        else
          {%{data | codec_decoder: new_decoder, frame_counter: new_frame_counter}, nil}
        end
    end
  end

  # Extract data bits from Codec events
  defp extract_data_bits(events) do
    events
    |> Enum.filter(fn {type, _} -> type == :data end)
    |> Enum.flat_map(fn {:data, bits} -> bits end)
  end

  # Pack decoded bits into bytes
  defp bits_to_bytes(bits) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(fn chunk -> length(chunk) == 8 end)  # Drop partial bytes
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        Bitwise.bor(acc, Bitwise.bsl(bit, 7 - idx))
      end)
    end)
    |> :binary.list_to_bin()
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp calculate_data_rate(wid, bw_khz) do
    # Calculate data rate based on waveform and bandwidth
    # Based on MIL-STD-188-110D Table D-I
    base_rate = case wid.waveform do
      1 -> 75      # BPSK, rate 1/2
      2 -> 150     # QPSK, rate 1/2
      3 -> 300     # 8-PSK, rate 1/2
      4 -> 600     # 16-QAM, rate 3/4
      5 -> 1200    # 32-QAM, rate 3/4
      6 -> 2400    # 64-QAM, rate 3/4
      7 -> 3200    # 64-QAM, rate 1/2
      8 -> 4800    # 64-QAM, rate 1/2
      9 -> 6400    # 64-QAM, rate 1/2
      10 -> 8000   # 64-QAM, rate 1/2
      11 -> 9600   # 64-QAM, rate 1/2
      12 -> 12800  # 64-QAM, rate 1/2
      _ -> 4800
    end

    # Scale by bandwidth (3kHz is baseline)
    div(base_rate * bw_khz, 3)
  end

  defp calculate_blocking_factor(wid, bw_khz) do
    try do
      data_symbols = Tables.data_symbols(wid.waveform, bw_khz)
      bits_per_sym = Tables.bits_per_symbol(Tables.modulation(wid.waveform))
      data_symbols * bits_per_sym
    rescue
      _ -> 0
    end
  end

  defp build_status(data, state) do
    %{
      state: state,
      data_rate: data.data_rate,
      blocking_factor: data.blocking_factor,
      packet_count: data.packet_count,
      total_bytes: data.total_bytes,
      wid: data.wid,
      phy_state: PhyRx.state(data.phy_rx)
    }
  end

  defp emit_carrier_status(data, state) do
    event = case state do
      :no_carrier ->
        {:rx_carrier, :lost, %{}}

      :carrier_detected ->
        {:rx_carrier, :detected, %{
          data_rate: data.data_rate,
          blocking_factor: data.blocking_factor,
          wid: data.wid
        }}

      :receiving ->
        {:rx_carrier, :receiving, %{
          data_rate: data.data_rate,
          blocking_factor: data.blocking_factor
        }}
    end

    Events.broadcast(data.rig_id, {:modem, event})
  end

  defp emit_rx_data(rig_id, payload, order) do
    Events.broadcast(rig_id, {:modem, {:rx_data, payload, order}})
  end

  defp via_arbiter(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :arbiter}}}
  end
end
