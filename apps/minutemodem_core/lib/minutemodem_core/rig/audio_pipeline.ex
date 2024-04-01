defmodule MinuteModemCore.Rig.AudioPipeline do
  @moduledoc """
  Per-rig audio pipeline.

  Subscribes to modem events and routes TX audio:
  - For physical rigs: to the global Audio.Pipeline (PortAudio speakers)
  - For simnet rigs: to SimnetBridge (channel simulation)
  """

  use GenServer

  require Logger

  alias MinuteModemCore.Modem.Events
  alias MinuteModemCore.Audio.Pipeline, as: AudioPipeline
  alias MinuteModemCore.Rig.SimnetBridge

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio_pipeline}}}
  end

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    rig_type = Keyword.get(opts, :rig_type, "test")
    sample_rate = 9600

    # Determine if this rig uses simnet (test/simulator rigs)
    use_simnet = rig_type in ["test", "simulator"]

    Logger.info("AudioPipeline started for rig #{rig_id}, sample_rate=#{sample_rate}, simnet=#{use_simnet}")

    {:ok, %{
      rig_id: rig_id,
      rig_type: rig_type,
      sample_rate: sample_rate,
      use_simnet: use_simnet,
      subscribed: false,
      opts: opts
    }, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    Process.send_after(self(), :subscribe, 100)
    {:noreply, state}
  end

  @impl true
  def handle_info(:subscribe, %{subscribed: false} = state) do
    case Events.subscribe(state.rig_id, self(), filter: :tx) do
      :ok ->
        Logger.debug("[Rig.AudioPipeline] Subscribed to modem events")
        {:noreply, %{state | subscribed: true}}
      _ ->
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  def handle_info(:subscribe, state), do: {:noreply, state}

  @impl true
  def handle_info({:modem, {:tx_audio, samples}}, state) do
    audio_binary = samples_to_binary(samples)

    if state.use_simnet do
      # Route through simnet channel simulation
      Logger.debug("[Rig.AudioPipeline] TX #{byte_size(audio_binary)} bytes via simnet")

      # Convert to f32 for simnet (it expects f32 native)
      f32_binary = s16_to_f32(audio_binary)

      case SimnetBridge.tx(state.rig_id, f32_binary) do
        :ok -> :ok
        {:error, :not_attached} ->
          Logger.warning("[Rig.AudioPipeline] SimnetBridge not attached, falling back to speakers")
          AudioPipeline.play_tx(audio_binary, state.sample_rate, rig_id: state.rig_id)
        {:error, reason} ->
          Logger.warning("[Rig.AudioPipeline] SimnetBridge TX failed: #{inspect(reason)}")
      end
    else
      # Physical rig - play through speakers
      Logger.debug("[Rig.AudioPipeline] Playing #{byte_size(audio_binary)} bytes of TX audio")
      AudioPipeline.play_tx(audio_binary, state.sample_rate, rig_id: state.rig_id)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:modem, {:tx_status, _status}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:modem, _other}, state) do
    {:noreply, state}
  end

  # Convert sample list to binary (signed 16-bit little-endian)
  defp samples_to_binary(samples) when is_list(samples) do
    samples
    |> Enum.map(fn sample -> <<sample::signed-little-16>> end)
    |> IO.iodata_to_binary()
  end

  defp samples_to_binary(binary) when is_binary(binary), do: binary

  # Convert s16 binary to f32 binary for simnet
  defp s16_to_f32(binary) do
    for <<sample::signed-little-16 <- binary>>, into: <<>> do
      # Normalize to -1.0..1.0 range
      f = sample / 32768.0
      <<f::float-32-native>>
    end
  end
end
