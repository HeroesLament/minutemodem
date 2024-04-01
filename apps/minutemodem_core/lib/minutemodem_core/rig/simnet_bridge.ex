defmodule MinuteModemCore.Rig.SimnetBridge do
  @moduledoc """
  Bridge between MinuteModemCore rigs and MinutemodemSimnet.

  For simulator/test rigs, this module:
  - Attaches the rig to simnet with physical configuration
  - Subscribes to simnet RX and forwards to Rig.Audio subscribers
  - Routes TX audio through simnet channel simulation

  Works in distributed mode - simnet runs on a separate node and
  communication happens via RPC through SimnetClient.

  ## Physical Configuration

  Simnet requires physical parameters for propagation modeling.
  These can be provided in the rig's `control_config`:

      %{
        "location" => {lat, lon},           # Required for propagation
        "antenna" => %{
          "type" => "dipole",               # dipole, vertical, inverted_v
          "height_wavelengths" => 0.5
        },
        "tx_power_watts" => 100,
        "noise_floor_dbm" => -100.0
      }

  If not provided, defaults are used (test location in Fairbanks, AK).
  """

  use GenServer

  require Logger

  alias MinuteModemCore.Rig.SimnetClient

  @default_location {64.8378, -147.7164}  # Fairbanks, AK
  @default_antenna %{type: :dipole, height_wavelengths: 0.5}
  @default_tx_power 100
  @default_noise_floor -100.0

  defstruct [
    :rig_id,
    :sample_rate,
    :block_samples,
    :current_freq_hz,
    :tx_sample_index,
    :attached
  ]

  # --- Public API ---

  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec, name: via(spec.id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :simnet_bridge}}}
  end

  @doc """
  Set the operating frequency for simnet propagation.
  Called when rig frequency changes.
  """
  def set_frequency(rig_id, freq_hz) do
    GenServer.cast(via(rig_id), {:set_frequency, freq_hz})
  end

  @doc """
  Transmit audio samples through simnet.
  Samples should be f32 native format.
  """
  def tx(rig_id, samples) when is_binary(samples) do
    GenServer.call(via(rig_id), {:tx, samples})
  end

  @doc """
  Check if simnet node is available and connected.
  """
  def simnet_available? do
    SimnetClient.available?()
  end

  # --- GenServer Implementation ---

  @impl true
  def init(spec) do
    rig_id = spec.id
    config = spec.control_config || %{}

    state = %__MODULE__{
      rig_id: rig_id,
      sample_rate: 9600,
      block_samples: 96,  # 2ms at 48kHz
      current_freq_hz: 7_300_000,  # Default 40m
      tx_sample_index: 0,
      attached: false
    }

    # Try to connect to simnet node
    case SimnetClient.ensure_connected() do
      :ok ->
        # Attach to simnet
        case attach_to_simnet(rig_id, config) do
          :ok ->
            Logger.info("[SimnetBridge] Rig #{rig_id} attached to simnet")
            {:ok, %{state | attached: true}}

          {:error, reason} ->
            Logger.warning("[SimnetBridge] Could not attach #{rig_id} to simnet: #{inspect(reason)}")
            {:ok, state}
        end

      {:error, reason} ->
        Logger.info("[SimnetBridge] Simnet node not available: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:set_frequency, freq_hz}, state) do
    {:noreply, %{state | current_freq_hz: freq_hz}}
  end

  @impl true
  def handle_call({:tx, _samples}, _from, %{attached: false} = state) do
    {:reply, {:error, :not_attached}, state}
  end

  @impl true
  def handle_call({:tx, samples}, _from, state) do
    result = do_tx(state.rig_id, state.tx_sample_index, samples, state.current_freq_hz)

    n_samples = byte_size(samples) |> div(4)  # f32 = 4 bytes
    new_index = state.tx_sample_index + n_samples

    {:reply, result, %{state | tx_sample_index: new_index}}
  end

  @impl true
  def handle_info({:simnet_rx, from_rig, t0, samples, freq_hz, metadata}, state) do
    # Log simnet channel conditions
    Logger.debug("[SimnetBridge] RX from #{inspect(from_rig)}: SNR=#{metadata[:snr_db]}dB, regime=#{metadata[:regime]}, doppler=#{metadata[:doppler_bandwidth_hz]}Hz")

    # Forward to Rig.Audio subscribers
    s16_samples = f32_to_s16_list(samples)
    broadcast_rx_audio(state.rig_id, from_rig, s16_samples, metadata)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[SimnetBridge] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{attached: true, rig_id: rig_id}) do
    SimnetClient.unsubscribe_rx(rig_id)
    SimnetClient.detach_rig(rig_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Internal ---

  defp attach_to_simnet(rig_id, config) do
    physical_config = build_physical_config(config)

    case SimnetClient.attach_rig(rig_id, physical_config) do
      {:ok, _} ->
        SimnetClient.subscribe_rx(rig_id, self())
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_physical_config(config) do
    location = get_location(config)
    antenna = get_antenna(config)
    tx_power = Map.get(config, "tx_power_watts", @default_tx_power)
    noise_floor = Map.get(config, "noise_floor_dbm", @default_noise_floor)

    %{
      sample_rates: [9600],
      block_ms: [2],
      representation: [:audio_f32],
      location: location,
      antenna: antenna,
      tx_power_watts: tx_power,
      noise_floor_dbm: noise_floor
    }
  end

  defp get_location(config) do
    case Map.get(config, "location") do
      {lat, lon} when is_number(lat) and is_number(lon) -> {lat, lon}
      [lat, lon] when is_number(lat) and is_number(lon) -> {lat, lon}
      _ -> @default_location
    end
  end

  defp get_antenna(config) do
    case Map.get(config, "antenna") do
      %{"type" => type} = ant ->
        %{
          type: String.to_existing_atom(type),
          height_wavelengths: Map.get(ant, "height_wavelengths", 0.5)
        }
      _ ->
        @default_antenna
    end
  end

  defp do_tx(rig_id, t0, samples, freq_hz) do
    SimnetClient.tx(rig_id, t0, samples, freq_hz: freq_hz)
  end

  # Convert f32 samples from simnet to s16 for receiver
  # Simnet's Watterson channel model can produce samples > 1.0 due to
  # multipath constructive interference and noise. We normalize to prevent
  # clipping which corrupts the demodulated symbols.
  defp f32_to_s16_list(binary) do
    # First pass: extract samples and find peak amplitude
    samples = for <<sample::float-32-native <- binary>>, do: sample
    peak = samples |> Enum.map(&abs/1) |> Enum.max(fn -> 1.0 end)

    # Normalize if peak > 1.0 to prevent clipping
    # Target 0.9 to leave some headroom
    scale = if peak > 0.9, do: 0.9 / peak, else: 1.0

    Enum.map(samples, fn sample ->
      round(sample * scale * 32767.0)
    end)
  end

  defp broadcast_rx_audio(rig_id, from_rig, samples, metadata) do
    msg = {:rx_audio, rig_id, samples, %{from: from_rig, simnet: metadata}}

    :pg.get_members(:minutemodem_pg, {:rig_rx, rig_id})
    |> Enum.each(fn pid -> send(pid, msg) end)

    try do
      audio_pid = GenServer.whereis(MinuteModemCore.Rig.Audio.via(rig_id))
      if audio_pid do
        send(audio_pid, {:simnet_rx, from_rig, samples, metadata})
      end
    rescue
      _ -> :ok
    end
  end
end
