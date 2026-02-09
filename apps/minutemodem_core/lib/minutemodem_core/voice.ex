defmodule MinuteModemCore.Voice do
  @moduledoc """
  Digital Voice (DV) processor for a rig.

  Marries the MELPe 600 bps vocoder to the 110D modem at the bitstream
  level. Sits between `Rig.AudioEndpoint` (operator PCM) and
  `Modem.TxFSM` / `Modem.Events` (modem data plane).

  ## TX Path

      AudioEndpoint.push_voice_tx(pcm)
        → Voice: accumulate 540 samples
        → MELPe encode → 6 bytes
        → Frame: prepend sync + seq
        → Modem.arm_tx / tx_data / start_tx
        → 110D waveform out the radio

  ## RX Path

      Modem.Events {:modem, {:rx_data, data, order}}
        → Voice: deframe, extract vocoder bytes
        → MELPe decode → 540 samples → PCM
        → AudioEndpoint.deliver_voice_rx(pcm)

  ## Framing

  DV frames are simple TLV wrappers around MELPe superframes carried
  as 110D data. The modem provides FEC, interleaving, and symbol mapping
  — we don't duplicate that.

      <<@frame_magic::8, seq::8, vocoder_bytes::binary-size(6)>>

  8 bytes total per DV frame. The magic byte lets the RX side
  distinguish DV traffic from raw data. The sequence number lets
  us detect gaps for concealment.

  ## Lifecycle

  Started in the rig supervision tree. Idles until AudioEndpoint
  calls `tx_begin/1` (on PTT/VOX acquire) and `tx_end/1` (on release).
  On the RX side, it's always listening to Modem.Events.

  ## MELPe Geometry

  - 540 samples at 8 kHz (67.5 ms) → 6 bytes (48 bits)
  - We accumulate PCM in a buffer until we have a full superframe
  """

  use GenServer

  require Logger

  alias MinuteModemCore.DSP.Melpe
  alias MinuteModemCore.Modem
  alias MinuteModemCore.Modem.Events, as: ModemEvents
  alias MinuteModemCore.Rig.AudioEndpoint

  # MELPe geometry
  @superframe_samples 540
  @superframe_bytes 6

  # DV frame format: <<magic::8, seq::8, vocoder::binary-6>>
  @frame_magic 0xD6
  @frame_size @superframe_bytes + 2

  defstruct [
    :rig_id,
    :encoder,
    :decoder,
    :tx_buffer,         # accumulated s16le PCM awaiting a full superframe
    :tx_seq,            # TX frame sequence counter (0-255)
    :tx_active,         # true when AudioEndpoint has acquired voice TX
    :rx_seq,            # last received sequence number (for gap detection)
    :modem_armed        # true when we've armed TxFSM for a voice burst
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :voice}}}
  end

  @doc """
  Called by AudioEndpoint when voice TX is acquired (PTT/VOX/BYPASS on).
  Arms the modem and prepares for streaming vocoder frames.
  """
  def tx_begin(rig_id) do
    GenServer.cast(via(rig_id), :tx_begin)
  end

  @doc """
  Called by AudioEndpoint when voice TX is released.
  Flushes any remaining buffer, sends :last frame, drains modem.
  """
  def tx_end(rig_id) do
    GenServer.cast(via(rig_id), :tx_end)
  end

  @doc """
  Called by AudioEndpoint with operator mic PCM (s16le binary, 8 kHz mono).
  Accumulates samples, encodes full superframes, and injects into modem.
  """
  def push_tx_audio(rig_id, pcm) when is_binary(pcm) do
    GenServer.cast(via(rig_id), {:tx_audio, pcm})
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    # Create vocoder instances
    encoder = Melpe.encoder_new()
    decoder = Melpe.decoder_new()

    # Subscribe to modem RX data for voice decode
    ModemEvents.subscribe(rig_id, self(), filter: :rx)

    state = %__MODULE__{
      rig_id: rig_id,
      encoder: encoder,
      decoder: decoder,
      tx_buffer: <<>>,
      tx_seq: 0,
      tx_active: false,
      rx_seq: nil,
      modem_armed: false
    }

    Logger.info("[Voice] Started for rig #{short(rig_id)}")
    {:ok, state}
  end

  # --- TX lifecycle ---

  @impl true
  def handle_cast(:tx_begin, state) do
    state = %{state | tx_active: true, tx_buffer: <<>>, tx_seq: 0}

    # Reset encoder for fresh TX session
    Melpe.encoder_reset(state.encoder)

    # Arm the modem for voice data
    state = arm_modem(state)

    Logger.debug("[Voice] TX begin for rig #{short(state.rig_id)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:tx_end, state) do
    state = flush_tx_buffer(state)
    state = drain_modem(state)
    state = %{state | tx_active: false, modem_armed: false}

    Logger.debug("[Voice] TX end for rig #{short(state.rig_id)}")
    {:noreply, state}
  end

  # --- TX audio from AudioEndpoint ---

  @impl true
  def handle_cast({:tx_audio, _pcm}, %{tx_active: false} = state) do
    # Not transmitting — drop
    {:noreply, state}
  end

  @impl true
  def handle_cast({:tx_audio, pcm}, state) do
    state = accumulate_and_encode(pcm, state)
    {:noreply, state}
  end

  # --- RX data from Modem.Events ---

  @impl true
  def handle_info({:modem, {:rx_data, data, _order}}, state) do
    state = process_rx_data(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:modem, {:rx_complete, _info}}, state) do
    # RX burst complete — reset decoder for next burst
    Melpe.decoder_reset(state.decoder)
    {:noreply, %{state | rx_seq: nil}}
  end

  @impl true
  def handle_info({:modem, _other}, state) do
    # Ignore other modem events (carrier, tx_status, etc)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ===========================================================================
  # TX: Accumulate PCM → MELPe encode → frame → inject into modem
  # ===========================================================================

  # s16le samples are 2 bytes each. We need 540 samples = 1080 bytes.
  @superframe_pcm_bytes @superframe_samples * 2

  defp accumulate_and_encode(pcm, state) do
    buffer = state.tx_buffer <> pcm
    encode_loop(buffer, state)
  end

  defp encode_loop(buffer, state) when byte_size(buffer) >= @superframe_pcm_bytes do
    <<superframe_pcm::binary-size(@superframe_pcm_bytes), rest::binary>> = buffer

    # Convert s16le binary to list of f64 for MELPe NIF
    samples = s16le_to_f64_list(superframe_pcm)

    # Encode
    case Melpe.encode(state.encoder, samples) do
      vocoder_bytes when is_list(vocoder_bytes) ->
        # Frame it
        frame = build_dv_frame(state.tx_seq, :erlang.list_to_binary(vocoder_bytes))

        # Inject into modem
        state = inject_frame(frame, state)
        state = %{state | tx_seq: rem(state.tx_seq + 1, 256)}

        # Continue if there's more in the buffer
        encode_loop(rest, %{state | tx_buffer: rest})

      {:error, reason} ->
        Logger.warning("[Voice] MELPe encode error: #{inspect(reason)}")
        %{state | tx_buffer: rest}
    end
  end

  defp encode_loop(buffer, state) do
    %{state | tx_buffer: buffer}
  end

  defp s16le_to_f64_list(pcm) do
    for <<sample::signed-little-16 <- pcm>>, do: sample / 32768.0
  end

  # ===========================================================================
  # TX: DV frame format
  # ===========================================================================

  defp build_dv_frame(seq, vocoder_bytes) when byte_size(vocoder_bytes) == @superframe_bytes do
    <<@frame_magic::8, seq::8, vocoder_bytes::binary>>
  end

  # ===========================================================================
  # TX: Modem injection
  # ===========================================================================

  defp arm_modem(state) do
    case Modem.arm_tx(state.rig_id) do
      {:ok, _} ->
        %{state | modem_armed: true}

      {:error, reason} ->
        Logger.warning("[Voice] Modem arm failed: #{inspect(reason)}")
        state
    end
  end

  defp inject_frame(frame, %{modem_armed: false} = state) do
    # Try to arm first
    state = arm_modem(state)
    if state.modem_armed, do: inject_frame(frame, state), else: state
  end

  defp inject_frame(frame, state) do
    # First frame triggers start
    order = if state.tx_seq == 0, do: :first, else: :continuation

    case Modem.tx_data(state.rig_id, frame, order: order) do
      :ok ->
        # Start TX on first frame
        if state.tx_seq == 0 do
          Modem.start_tx(state.rig_id)
        end

        state

      {:error, reason} ->
        Logger.warning("[Voice] Modem tx_data failed: #{inspect(reason)}")
        state
    end
  end

  defp drain_modem(%{modem_armed: false} = state), do: state

  defp drain_modem(state) do
    # Send an empty :last to signal end-of-voice
    case Modem.tx_data(state.rig_id, <<>>, order: :last) do
      :ok -> :ok
      {:error, _} -> :ok
    end

    state
  end

  # Flush partial buffer at end of TX — zero-pad to full superframe
  defp flush_tx_buffer(%{tx_buffer: <<>>} = state), do: state

  defp flush_tx_buffer(%{tx_buffer: buffer} = state) when byte_size(buffer) > 0 do
    pad_bytes = @superframe_pcm_bytes - byte_size(buffer)
    padded = buffer <> :binary.copy(<<0, 0>>, div(pad_bytes, 2))

    samples = s16le_to_f64_list(padded)

    case Melpe.encode(state.encoder, samples) do
      vocoder_bytes when is_list(vocoder_bytes) ->
        frame = build_dv_frame(state.tx_seq, :erlang.list_to_binary(vocoder_bytes))
        inject_frame(frame, state)

      _ ->
        :ok
    end

    %{state | tx_buffer: <<>>}
  end

  defp flush_tx_buffer(state), do: state

  # ===========================================================================
  # RX: Modem data → deframe → MELPe decode → AudioEndpoint
  # ===========================================================================

  defp process_rx_data(data, state) do
    deframe_loop(data, state)
  end

  defp deframe_loop(<<@frame_magic::8, seq::8, vocoder::binary-size(@superframe_bytes), rest::binary>>, state) do
    # Gap detection
    state = if state.rx_seq != nil do
      expected = rem(state.rx_seq + 1, 256)
      if seq != expected do
        gap = rem(seq - state.rx_seq + 256, 256) - 1
        Logger.debug("[Voice] RX gap: #{gap} frames missing (expected #{expected}, got #{seq})")
        # TODO: concealment — decode silence frames for the gap
      end
      state
    else
      state
    end

    # Decode
    case Melpe.decode(state.decoder, :erlang.binary_to_list(vocoder)) do
      samples when is_list(samples) ->
        pcm = f64_list_to_s16le(samples)
        AudioEndpoint.deliver_voice_rx(state.rig_id, pcm)

      {:error, reason} ->
        Logger.warning("[Voice] MELPe decode error: #{inspect(reason)}")
    end

    deframe_loop(rest, %{state | rx_seq: seq})
  end

  # Non-DV data or partial frame — skip
  defp deframe_loop(_data, state), do: state

  defp f64_list_to_s16le(samples) do
    for s <- samples, into: <<>> do
      clamped = max(-1.0, min(1.0, s))
      <<round(clamped * 32767)::signed-little-16>>
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(id), do: inspect(id)
end
