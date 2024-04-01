defmodule MinuteModemCore.Rig.Audio do
  @moduledoc """
  Per-rig audio manager.

  Responsibilities:
  - Routes RX audio to DSP pipeline consumers
  - Routes TX audio from DSP pipeline to soundcard
  - For test rigs: injects audio from files on demand
  - For simnet rigs: receives RX from channel simulation

  Audio is distributed via a simple pubsub mechanism -
  consumers subscribe and receive `{:rx_audio, samples}` messages.
  """

  use GenServer

  require Logger

  alias MinuteModemCore.Rig.Types, as: RigTypes

  defstruct [
    :rig_id,
    :rig_type,
    :rx_device,
    :tx_device,
    :audio_config,
    :playback_state,
    subscribers: MapSet.new()
  ]

  # --- Public API ---

  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec, name: via(spec.id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio}}}
  end

  @doc """
  Subscribe to RX audio. Subscriber will receive:
    {:rx_audio, rig_id, samples}

  For simnet rigs, additional metadata is available:
    {:rx_audio, rig_id, samples, %{from: source_rig, simnet: %{regime: ..., snr_db: ...}}}
  """
  def subscribe(rig_id) do
    GenServer.call(via(rig_id), {:subscribe, self()})
  end

  def unsubscribe(rig_id) do
    GenServer.call(via(rig_id), {:unsubscribe, self()})
  end

  @doc """
  For test rigs: play an audio file into the RX stream.
  Options:
    - :loop - boolean, loop playback
  """
  def play_file(rig_id, file_path, opts \\ []) do
    GenServer.call(via(rig_id), {:play_file, file_path, opts})
  end

  @doc """
  Stop any in-progress file playback.
  """
  def stop_playback(rig_id) do
    GenServer.cast(via(rig_id), :stop_playback)
  end

  @doc """
  Get current playback state for UI.
  Returns: :idle | {:playing, file_path, progress_percent}
  """
  def playback_state(rig_id) do
    GenServer.call(via(rig_id), :playback_state)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(spec) do
    rig_type = spec.rig_type || "test"
    type_module = RigTypes.module_for(rig_type)

    audio_config =
      if type_module do
        type_module.audio_config()
      else
        %{sample_rate: 9600, channels: 1, format: :s16le}
      end

    state = %__MODULE__{
      rig_id: spec.id,
      rig_type: rig_type,
      rx_device: spec.rx_audio,
      tx_device: spec.tx_audio,
      audio_config: audio_config,
      playback_state: :idle
    }

    Logger.info("[Rig.Audio] Started for rig #{spec.id} (type: #{rig_type}, #{audio_config.sample_rate}Hz)")

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subs = MapSet.put(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subs}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subs}}
  end

  @impl true
  def handle_call({:play_file, file_path, opts}, _from, state) do
    case start_playback(file_path, opts, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} = err ->
        Logger.warning("[Rig.Audio] Failed to play #{file_path}: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:playback_state, _from, state) do
    reply =
      case state.playback_state do
        :idle ->
          :idle

        %{file: file, samples_played: played, total_samples: total} ->
          progress = if total > 0, do: round(played / total * 100), else: 0
          {:playing, file, progress}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:stop_playback, state) do
    {:noreply, %{state | playback_state: :idle}}
  end

  @impl true
  def handle_info(:playback_tick, %{playback_state: :idle} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:playback_tick, state) do
    case emit_playback_chunk(state) do
      {:continue, new_state} ->
        schedule_playback_tick()
        {:noreply, new_state}

      {:finished, new_state} ->
        Logger.debug("[Rig.Audio] Playback finished for rig #{state.rig_id}")
        {:noreply, new_state}
    end
  end

  # Handle simnet RX forwarded from SimnetBridge
  @impl true
  def handle_info({:simnet_rx, from_rig, samples, metadata}, state) do
    # Broadcast to subscribers with simnet metadata
    broadcast_rx_audio_with_metadata(state.rig_id, samples, %{
      from: from_rig,
      simnet: metadata
    }, state.subscribers)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subs}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Rig.Audio] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Internal: File Playback ---

  # Chunk size in samples (at 8kHz, 160 samples = 20ms)
  @chunk_samples 160
  # Playback tick interval in ms
  @tick_interval_ms 20

  defp start_playback(file_path, opts, state) do
    with {:ok, samples} <- load_audio_file(file_path) do
      playback = %{
        file: file_path,
        samples: samples,
        total_samples: length(samples),
        samples_played: 0,
        loop: Keyword.get(opts, :loop, false)
      }

      schedule_playback_tick()

      {:ok, %{state | playback_state: playback}}
    end
  end

  defp load_audio_file(file_path) do
    # TODO: Support WAV parsing, sample rate conversion
    # For now, assume raw 16-bit signed LE mono 8kHz
    case File.read(file_path) do
      {:ok, binary} ->
        samples = for <<sample::little-signed-16 <- binary>>, do: sample
        {:ok, samples}

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp schedule_playback_tick do
    Process.send_after(self(), :playback_tick, @tick_interval_ms)
  end

  defp emit_playback_chunk(%{playback_state: pb} = state) do
    chunk = Enum.take(pb.samples, @chunk_samples)
    remaining = Enum.drop(pb.samples, @chunk_samples)
    played = pb.samples_played + length(chunk)

    # Broadcast to subscribers
    broadcast_rx_audio(state.rig_id, chunk, state.subscribers)

    cond do
      remaining != [] ->
        new_pb = %{pb | samples: remaining, samples_played: played}
        {:continue, %{state | playback_state: new_pb}}

      pb.loop ->
        # Reload from beginning
        {:ok, fresh_samples} = load_audio_file(pb.file)
        new_pb = %{pb | samples: fresh_samples, samples_played: 0}
        {:continue, %{state | playback_state: new_pb}}

      true ->
        {:finished, %{state | playback_state: :idle}}
    end
  end

  defp broadcast_rx_audio(rig_id, samples, subscribers) do
    msg = {:rx_audio, rig_id, samples}

    Enum.each(subscribers, fn pid ->
      send(pid, msg)
    end)
  end

  defp broadcast_rx_audio_with_metadata(rig_id, samples, metadata, subscribers) do
    msg = {:rx_audio, rig_id, samples, metadata}

    Enum.each(subscribers, fn pid ->
      send(pid, msg)
    end)
  end
end
