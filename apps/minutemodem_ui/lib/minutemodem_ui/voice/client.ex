defmodule MinuteModemUI.Voice.Client do
  @moduledoc """
  Voice operations context — business logic for operator voice.

  Owns an `Audio.Session` (transport to core) and a local Membrane
  pipeline (PortAudio sink for operator speaker).

  ## Controls

  - **START** — Attach to selected rig, open speaker pipeline, begin
    playing any received voice RX. The operator hears decoded audio.
  - **TX** — Assert PTT on the core rig (via AudioEndpoint). While held,
    operator mic PCM flows to core for MELPe encoding and transmission.
  - **STOP** — Release PTT if active, tear down speaker pipeline, detach
    from rig. Back to idle.

  ## Notifications to owner

  - `{:voice, :started, rig_id}`
  - `{:voice, :stopped}`
  - `{:voice, :start_failed, reason}`
  - `{:voice, :tx_on}`
  - `{:voice, :tx_off}`
  - `{:voice, :tx_status, owner}`       — from core (nil | :voice | :busy)
  """

  use GenServer

  require Logger

  alias MinuteModemUI.Audio.Session, as: AudioSession

  defstruct [
    :owner,
    :session,
    :rig_id,
    :speaker_pipeline,   # Membrane pipeline pid for speaker output
    :speaker_device_id,  # PortAudio device ID for operator speaker
    :active,             # true when START'd and attached
    :tx_held             # true when TX button is pressed
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, owner)
  end

  @doc """
  Start voice session: attach to rig, open speaker pipeline.
  `speaker_device_name` is the operator's selected output device name
  (from Config scene / Membrane.PortAudio.list_devices).
  """
  def start_voice(pid, rig_id, speaker_device_name) do
    GenServer.call(pid, {:start_voice, rig_id, speaker_device_name})
  end

  @doc "Stop voice session: release TX, close speaker, detach from rig."
  def stop_voice(pid) do
    GenServer.call(pid, :stop_voice)
  end

  @doc "Assert TX (PTT on)."
  def tx_on(pid) do
    GenServer.cast(pid, :tx_on)
  end

  @doc "Release TX (PTT off)."
  def tx_off(pid) do
    GenServer.cast(pid, :tx_off)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(owner) do
    {:ok, session} = AudioSession.start_link(owner: self())
    Process.monitor(owner)

    state = %__MODULE__{
      owner: owner,
      session: session,
      rig_id: nil,
      speaker_pipeline: nil,
      speaker_device_id: nil,
      active: false,
      tx_held: false
    }

    {:ok, state}
  end

  # --- START ---

  @impl true
  def handle_call({:start_voice, rig_id, speaker_device_name}, _from, state) do
    # Tear down any existing session first
    state = do_stop(state)

    # Resolve speaker device
    speaker_device_id = resolve_output_device(speaker_device_name)

    # Attach to rig
    case AudioSession.attach(state.session, rig_id) do
      :ok ->
        # Start speaker pipeline
        state = %{state |
          rig_id: rig_id,
          speaker_device_id: speaker_device_id,
          active: true
        }

        state = start_speaker_pipeline(state)

        Logger.info("[Voice.Client] Started on rig #{short(rig_id)}")
        notify(state.owner, {:voice, :started, rig_id})
        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.warning("[Voice.Client] Attach failed: #{inspect(reason)}")
        notify(state.owner, {:voice, :start_failed, reason})
        {:reply, err, state}
    end
  end

  # --- STOP ---

  @impl true
  def handle_call(:stop_voice, _from, state) do
    state = do_stop(state)
    {:reply, :ok, state}
  end

  # --- TX on/off ---

  @impl true
  def handle_cast(:tx_on, %{active: true, tx_held: false} = state) do
    AudioSession.voice_signal(state.session, {:ptt, :on})
    notify(state.owner, {:voice, :tx_on})
    {:noreply, %{state | tx_held: true}}
  end

  def handle_cast(:tx_on, state), do: {:noreply, state}

  @impl true
  def handle_cast(:tx_off, %{tx_held: true} = state) do
    AudioSession.voice_signal(state.session, {:ptt, :off})
    notify(state.owner, {:voice, :tx_off})
    {:noreply, %{state | tx_held: false}}
  end

  def handle_cast(:tx_off, state), do: {:noreply, state}

  # --- Session notifications ---

  @impl true
  def handle_info({:session, :attached, _rig_id}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:session, :detached}, state) do
    notify(state.owner, {:voice, :stopped})
    {:noreply, %{state | active: false, tx_held: false, rig_id: nil}}
  end

  @impl true
  def handle_info({:session, :attach_failed, reason}, state) do
    notify(state.owner, {:voice, :start_failed, reason})
    {:noreply, %{state | active: false}}
  end

  @impl true
  def handle_info({:session, :tx_status, owner}, state) do
    notify(state.owner, {:voice, :tx_status, owner})
    {:noreply, state}
  end

  @impl true
  def handle_info({:session, :voice_rx, pcm}, state) do
    push_to_speaker(pcm, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:session, :rig_rx, _samples}, state) do
    # Channel audio — not used by Voice.Client currently.
    # Could forward to a spectrogram canvas in the future.
    {:noreply, state}
  end

  # --- Owner died ---

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{owner: pid} = state) do
    do_stop(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_stop(state)
    :ok
  end

  # ===========================================================================
  # Internal: Start / Stop
  # ===========================================================================

  defp do_stop(%{active: false} = state), do: state

  defp do_stop(state) do
    # Release TX if held
    if state.tx_held do
      AudioSession.voice_signal(state.session, {:ptt, :off})
    end

    # Stop speaker pipeline
    state = stop_speaker_pipeline(state)

    # Detach from rig
    AudioSession.detach(state.session)

    notify(state.owner, {:voice, :stopped})

    %{state |
      active: false,
      tx_held: false,
      rig_id: nil,
      speaker_device_id: nil
    }
  end

  # ===========================================================================
  # Internal: Speaker pipeline (Membrane PortAudio Sink)
  # ===========================================================================

  defp start_speaker_pipeline(%{speaker_device_id: nil} = state) do
    Logger.warning("[Voice.Client] No speaker device — voice RX will be silent")
    state
  end

  defp start_speaker_pipeline(state) do
    opts = [
      speaker_device_id: state.speaker_device_id,
      sample_rate: 8000
    ]

    case Membrane.Pipeline.start_link(MinuteModemUI.Audio.SpeakerPipeline, opts) do
      {:ok, _supervisor, pipeline} ->
        Process.monitor(pipeline)
        Logger.debug("[Voice.Client] Speaker pipeline started")
        %{state | speaker_pipeline: pipeline}

      {:error, reason} ->
        Logger.warning("[Voice.Client] Speaker pipeline failed: #{inspect(reason)}")
        %{state | speaker_pipeline: nil}
    end
  end

  defp stop_speaker_pipeline(%{speaker_pipeline: nil} = state), do: state

  defp stop_speaker_pipeline(%{speaker_pipeline: pipeline} = state) do
    Membrane.Pipeline.terminate(pipeline)
    %{state | speaker_pipeline: nil}
  rescue
    _ -> %{state | speaker_pipeline: nil}
  end

  defp push_to_speaker(_pcm, %{speaker_pipeline: nil}), do: :ok

  defp push_to_speaker(pcm, %{speaker_pipeline: pipeline}) do
    Membrane.Pipeline.notify_child(pipeline, :source, {:audio, pcm})
  rescue
    _ -> :ok
  end

  # ===========================================================================
  # Internal: Device resolution
  # ===========================================================================

  defp resolve_output_device(nil), do: resolve_default_output()
  defp resolve_output_device(""), do: resolve_default_output()

  defp resolve_output_device(name) when is_binary(name) do
    case Enum.find(Membrane.PortAudio.list_devices(), &(&1.name == name and &1.max_output_channels > 0)) do
      %{id: id} -> id
      nil ->
        Logger.warning("[Voice.Client] Speaker device '#{name}' not found, using default")
        resolve_default_output()
    end
  end

  defp resolve_default_output do
    case Enum.find(Membrane.PortAudio.list_devices(), &(&1.default_device == :output)) do
      %{id: id} -> id
      nil -> nil
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp notify(owner, msg), do: send(owner, msg)

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(id), do: inspect(id)
end
