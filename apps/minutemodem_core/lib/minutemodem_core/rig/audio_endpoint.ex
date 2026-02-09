defmodule MinuteModemCore.Rig.AudioEndpoint do
  @moduledoc """
  Unified audio transport endpoint for a rig.

  Provides the single attachment point for remote UI nodes to send and
  receive audio for a given rig. Each rig instance has one AudioEndpoint
  in its supervision tree.

  ## Responsibilities

  - Bridges operator voice PCM between UI node and the rig's voice subsystem
  - Forwards rig RX audio to UI for spectrogram/constellation display
  - Manages PTT/VOX/BYPASS signaling to Rig.Control

  This module is purely transport and signaling. It does NOT perform
  vocoding, framing, or modulation — those are handled by DV-Voice
  and the 110D modem respectively.

  ## Streams (core → UI)

  - `{:audio, rig_id, :rig_rx, samples}`   — raw channel audio (for canvases)
  - `{:audio, rig_id, :voice_rx, pcm}`     — decoded voice from DV-Voice
  - `{:audio, rig_id, :tx_status, owner}`  — TX ownership changes

  ## Streams (UI → core)

  - `push_voice_tx/2` — operator mic PCM, forwarded to DV-Voice
  - `voice_signal/2`  — PTT/VOX/BYPASS mode signals

  ## Attach / Detach

  A remote UI process calls `attach/2` to begin receiving streams.
  Only one UI attachment is active at a time (last-attach-wins).
  Detach is explicit or implicit via process monitor.
  """

  use GenServer

  require Logger

  alias MinuteModemCore.Rig.{Audio, Control}
  alias MinuteModemCore.Voice

  # VOX hang time before releasing TX (ms)
  @vox_hang_time_ms 500
  # VOX energy threshold (RMS of s16 samples)
  @vox_threshold 800

  defstruct [
    :rig_id,
    :attached_pid,
    :attached_ref,
    :voice_mode,        # :idle | :ptt | :vox | :bypass
    :ptt_held,          # true when PTT is actively pressed
    :vox_active,        # true when VOX has detected voice
    :vox_hang_timer,    # timer ref for VOX hang time
    :tx_acquired         # true when we hold Rig.Control TX ownership
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio_endpoint}}}
  end

  @doc """
  Attach a remote UI process to this rig's audio streams.

  The caller will receive:
  - `{:audio, rig_id, :rig_rx, samples}`   — raw channel audio
  - `{:audio, rig_id, :voice_rx, pcm}`     — decoded operator voice
  - `{:audio, rig_id, :tx_status, owner}`  — TX ownership changes

  Returns :ok.
  """
  def attach(rig_id, pid \\ self()) do
    GenServer.call(via(rig_id), {:attach, pid})
  end

  @doc """
  Detach from this rig's audio streams.
  """
  def detach(rig_id) do
    GenServer.call(via(rig_id), :detach)
  end

  @doc """
  Send a voice mode signal.

  Signals:
  - `{:ptt, :on | :off}`
  - `{:vox, true | false}`
  - `{:bypass, true | false}`
  """
  def voice_signal(rig_id, signal) do
    GenServer.cast(via(rig_id), {:voice_signal, signal})
  end

  @doc """
  Push operator voice TX audio (s16le binary, 8kHz mono).
  Forwarded to the rig's DV-Voice module for vocoding and framing.
  """
  def push_voice_tx(rig_id, pcm) when is_binary(pcm) do
    GenServer.cast(via(rig_id), {:voice_tx, pcm})
  end

  @doc """
  Called by DV-Voice to deliver decoded voice RX to the attached UI.
  """
  def deliver_voice_rx(rig_id, pcm) when is_binary(pcm) do
    GenServer.cast(via(rig_id), {:voice_rx, pcm})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    state = %__MODULE__{
      rig_id: rig_id,
      attached_pid: nil,
      attached_ref: nil,
      voice_mode: :idle,
      ptt_held: false,
      vox_active: false,
      vox_hang_timer: nil,
      tx_acquired: false
    }

    # Subscribe to rig RX audio for forwarding to UI (canvases, monitoring)
    Audio.subscribe(rig_id)

    Logger.info("[AudioEndpoint] Started for rig #{rig_id}")

    {:ok, state}
  end

  # --- Attach / Detach ---

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    state = do_detach(state)

    ref = Process.monitor(pid)
    Logger.info("[AudioEndpoint] UI attached from #{inspect(pid)} for rig #{state.rig_id}")

    {:reply, :ok, %{state | attached_pid: pid, attached_ref: ref}}
  end

  @impl true
  def handle_call(:detach, _from, state) do
    state = do_detach(state)
    {:reply, :ok, state}
  end

  # --- RX audio from Rig.Audio (rig channel audio → UI for canvases) ---

  @impl true
  def handle_info({:rx_audio, rig_id, samples}, state) do
    forward_to_ui(state, {:audio, rig_id, :rig_rx, samples})
    {:noreply, state}
  end

  @impl true
  def handle_info({:rx_audio, rig_id, samples, _metadata}, state) do
    forward_to_ui(state, {:audio, rig_id, :rig_rx, samples})
    {:noreply, state}
  end

  # --- Voice RX from DV-Voice (decoded voice → UI for operator speaker) ---

  @impl true
  def handle_cast({:voice_rx, pcm}, state) do
    forward_to_ui(state, {:audio, state.rig_id, :voice_rx, pcm})
    {:noreply, state}
  end

  # --- Voice TX from UI (operator mic → DV-Voice) ---

  @impl true
  def handle_cast({:voice_tx, pcm}, state) do
    state = handle_voice_tx(pcm, state)
    {:noreply, state}
  end

  # --- Voice signals from UI ---

  @impl true
  def handle_cast({:voice_signal, {:ptt, :on}}, state) do
    state = %{state | ptt_held: true, voice_mode: :ptt}
    state = maybe_acquire_tx(state)
    {:noreply, state}
  end

  def handle_cast({:voice_signal, {:ptt, :off}}, state) do
    state = %{state | ptt_held: false}

    state =
      if state.voice_mode == :ptt do
        state = maybe_release_tx(state)
        %{state | voice_mode: :idle}
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:voice_signal, {:vox, true}}, state) do
    {:noreply, %{state | voice_mode: :vox}}
  end

  def handle_cast({:voice_signal, {:vox, false}}, state) do
    state = maybe_release_tx(state)
    state = cancel_vox_timer(state)
    {:noreply, %{state | voice_mode: :idle, vox_active: false}}
  end

  def handle_cast({:voice_signal, {:bypass, true}}, state) do
    state = %{state | voice_mode: :bypass}
    state = maybe_acquire_tx(state)
    {:noreply, state}
  end

  def handle_cast({:voice_signal, {:bypass, false}}, state) do
    state = maybe_release_tx(state)
    {:noreply, %{state | voice_mode: :idle}}
  end

  # --- VOX hang timer ---

  @impl true
  def handle_info(:vox_hang_expired, state) do
    state = %{state | vox_hang_timer: nil}

    state =
      if state.voice_mode == :vox and not state.vox_active do
        maybe_release_tx(state)
      else
        state
      end

    {:noreply, state}
  end

  # --- Monitor: attached UI process died ---

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{attached_ref: ref} = state) do
    Logger.info("[AudioEndpoint] Attached UI died for rig #{state.rig_id}")
    state = do_detach(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[AudioEndpoint] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tx_acquired do
      Control.release_tx(state.rig_id, :voice)
    end

    :ok
  end

  # ============================================================================
  # Internal: Forward to attached UI
  # ============================================================================

  defp forward_to_ui(%{attached_pid: nil}, _msg), do: :ok
  defp forward_to_ui(%{attached_pid: pid}, msg), do: send(pid, msg)

  # ============================================================================
  # Internal: Voice TX routing
  # ============================================================================

  defp handle_voice_tx(_pcm, %{voice_mode: :idle} = state), do: state

  defp handle_voice_tx(pcm, %{voice_mode: :ptt} = state) do
    if state.ptt_held and state.tx_acquired do
      forward_to_dv_voice(pcm, state)
    end

    state
  end

  defp handle_voice_tx(pcm, %{voice_mode: :vox} = state) do
    state = vox_detect(pcm, state)

    if state.tx_acquired do
      forward_to_dv_voice(pcm, state)
    end

    state
  end

  defp handle_voice_tx(pcm, %{voice_mode: :bypass} = state) do
    if state.tx_acquired do
      forward_to_dv_voice(pcm, state)
    end

    state
  end

  defp forward_to_dv_voice(pcm, state) do
    Voice.push_tx_audio(state.rig_id, pcm)
  end

  # ============================================================================
  # Internal: VOX detection
  # ============================================================================

  defp vox_detect(pcm, state) do
    rms = compute_rms(pcm)

    if rms >= @vox_threshold do
      state = cancel_vox_timer(state)
      state = %{state | vox_active: true}
      maybe_acquire_tx(state)
    else
      if state.vox_active do
        state = %{state | vox_active: false}
        start_vox_hang_timer(state)
      else
        state
      end
    end
  end

  defp compute_rms(pcm) do
    samples = for <<s::signed-little-16 <- pcm>>, do: s
    count = length(samples)

    if count == 0 do
      0
    else
      sum_sq = Enum.reduce(samples, 0, fn s, acc -> acc + s * s end)
      :math.sqrt(sum_sq / count) |> round()
    end
  end

  defp start_vox_hang_timer(state) do
    state = cancel_vox_timer(state)
    ref = Process.send_after(self(), :vox_hang_expired, @vox_hang_time_ms)
    %{state | vox_hang_timer: ref}
  end

  defp cancel_vox_timer(%{vox_hang_timer: nil} = state), do: state

  defp cancel_vox_timer(%{vox_hang_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | vox_hang_timer: nil}
  end

  # ============================================================================
  # Internal: TX ownership
  # ============================================================================

  defp maybe_acquire_tx(%{tx_acquired: true} = state), do: state

  defp maybe_acquire_tx(state) do
    case Control.acquire_tx(state.rig_id, :voice) do
      :ok ->
        Logger.debug("[AudioEndpoint] TX acquired for rig #{state.rig_id}")
        Voice.tx_begin(state.rig_id)
        forward_to_ui(state, {:audio, state.rig_id, :tx_status, :voice})
        %{state | tx_acquired: true}

      {:error, :busy} ->
        Logger.debug("[AudioEndpoint] TX busy for rig #{state.rig_id}")
        forward_to_ui(state, {:audio, state.rig_id, :tx_status, :busy})
        state
    end
  end

  defp maybe_release_tx(%{tx_acquired: false} = state), do: state

  defp maybe_release_tx(state) do
    Voice.tx_end(state.rig_id)

    case Control.release_tx(state.rig_id, :voice) do
      :ok ->
        Logger.debug("[AudioEndpoint] TX released for rig #{state.rig_id}")
        forward_to_ui(state, {:audio, state.rig_id, :tx_status, nil})

      {:error, _} ->
        :ok
    end

    %{state | tx_acquired: false}
  end

  # ============================================================================
  # Internal: Detach cleanup
  # ============================================================================

  defp do_detach(%{attached_ref: nil} = state), do: state

  defp do_detach(state) do
    if state.attached_ref, do: Process.demonitor(state.attached_ref, [:flush])

    state = maybe_release_tx(state)
    state = cancel_vox_timer(state)

    %{state |
      attached_pid: nil,
      attached_ref: nil,
      voice_mode: :idle,
      ptt_held: false,
      vox_active: false,
      tx_acquired: false
    }
  end
end
