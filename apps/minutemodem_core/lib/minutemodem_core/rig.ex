defmodule MinuteModemCore.Rig do
  @moduledoc """
  Rig management facade.

  Provides high-level API for starting, stopping, and interacting
  with rig instances. Each rig runs as a supervised process tree
  containing control (PTT, freq, mode) and audio (RX/TX routing).

  ## Rig Types (Hardware Category)

  - `"test"` - Simulator, no hardware, can inject audio files
  - `"hf"` - HF transceiver (1.6-30 MHz)
  - `"hf_rx"` - HF receive-only (diversity, monitoring)
  - `"vhf"` - VHF/UHF transceiver

  ## Protocol Stacks

  - `"ale_2g"` - MIL-STD-188-141A
  - `"ale_3g"` - MIL-STD-188-141B
  - `"ale_4g"` - MIL-STD-188-141D
  - `"stanag_5066"` - STANAG 5066 + WTRP
  - `"packet"` - AX.25 packet
  - `"aprs"` - APRS

  ## Control Types (Backend)

  - `"simulator"` - No-op control (for testing)
  - `"rigctld"` - Hamlib rigctld backend
  - `"flrig"` - FLRig XMLRPC backend
  """

  alias MinuteModemCore.Rig.{Registry, Instance, Control, Audio}
  alias MinuteModemCore.Persistence.{Rigs, Schemas.Rig}

  require Logger

  # --- Lifecycle ---

  @doc """
  Start a rig from its database record.
  """
  def start(%Rig{} = rig) do
    spec = %{
      id: rig.id,
      name: rig.name,
      rig_type: rig.rig_type,
      protocol_stack: rig.protocol_stack,
      self_addr: rig.self_addr || 0x0000,
      control_type: rig.control_type,
      control_config: rig.control_config || %{},
      rx_audio: rig.rx_audio,
      tx_audio: rig.tx_audio,
      # Interface config - default to MIL-STD-188-110D Appendix A on port 3000
      interface_type: :mil110d,
      interface_port: 3000
    }

    start(spec)
  end

  def start(%{id: id} = spec) do
    child_spec = {Instance, spec}

    case DynamicSupervisor.start_child(MinuteModemCore.Rig.Supervisor, child_spec) do
      {:ok, pid} ->
        Registry.register(id, pid)
        Logger.info("[Rig] Started rig #{id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      error ->
        Logger.error("[Rig] Failed to start rig #{id}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Start a rig by its database ID.
  """
  def start_by_id(rig_id) do
    rig = Rigs.get_rig!(rig_id)
    start(rig)
  end

  @doc """
  Stop a running rig.
  """
  def stop(rig_id) do
    case Registry.get_pid(rig_id) do
      nil ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(MinuteModemCore.Rig.Supervisor, pid)
        Registry.unregister(rig_id)
        Logger.info("[Rig] Stopped rig #{rig_id}")
        :ok
    end
  end

  @doc """
  Start all enabled rigs from database.
  """
  def start_enabled do
    Rigs.list_rigs()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&start/1)
  end

  # --- Control API (delegated) ---

  defdelegate set_frequency(rig_id, freq_hz), to: Control
  defdelegate get_frequency(rig_id), to: Control
  defdelegate set_mode(rig_id, mode), to: Control
  defdelegate get_mode(rig_id), to: Control
  defdelegate ptt(rig_id, state), to: Control
  defdelegate get_ptt(rig_id), to: Control
  defdelegate acquire_tx(rig_id, owner), to: Control
  defdelegate release_tx(rig_id, owner), to: Control
  defdelegate tx_owner(rig_id), to: Control

  @doc "Get rig control status for UI"
  def status(rig_id), do: Control.status(rig_id)

  # --- Audio API (delegated) ---

  defdelegate subscribe_rx(rig_id), to: Audio, as: :subscribe
  defdelegate unsubscribe_rx(rig_id), to: Audio, as: :unsubscribe
  defdelegate play_file(rig_id, file_path, opts \\ []), to: Audio
  defdelegate stop_playback(rig_id), to: Audio
  defdelegate playback_state(rig_id), to: Audio

  # --- Audio Endpoint API (delegated) ---

  alias MinuteModemCore.Rig.AudioEndpoint

  defdelegate audio_attach(rig_id, pid \\ self()), to: AudioEndpoint, as: :attach
  defdelegate audio_detach(rig_id), to: AudioEndpoint, as: :detach
  defdelegate voice_signal(rig_id, signal), to: AudioEndpoint
  defdelegate push_voice_tx(rig_id, pcm), to: AudioEndpoint

  # --- Registry queries ---

  defdelegate list_running, to: Registry
  defdelegate list_configured, to: Registry
  defdelegate running?(rig_id), to: Registry

  # --- ALE API ---

  alias MinuteModemCore.ALE.{Link, Transmitter}

  @doc """
  Start ALE scanning mode.

  The rig will listen for incoming ALE calls (capture probes).

  ## Options
  - `:waveform` - `:deep` or `:fast` (default: `:fast`)
  """
  def ale_scan(rig_id, opts \\ []) do
    Link.scan(rig_id, opts)
  end

  @doc """
  Stop ALE scanning or cancel current operation.

  Returns the Link FSM to idle state.
  """
  def ale_stop(rig_id) do
    Link.stop(rig_id)
  end

  @doc """
  Initiate an ALE call to a destination address.

  ## Options
  - `:waveform` - `:deep` or `:fast` (default: `:deep`)
  - `:tuner_time_ms` - TLC duration for radio tuning (default: 0)
  - `:voice` - Voice capability flag (default: false)
  - `:traffic_type` - Traffic type code (default: 0)
  """
  def ale_call(rig_id, dest_addr, opts \\ []) do
    Link.call(rig_id, dest_addr, opts)
  end

  @doc """
  Terminate the current ALE link.
  """
  def ale_terminate(rig_id, reason \\ :normal) do
    Link.terminate_link(rig_id, reason)
  end

  @doc """
  Get the current ALE link state.
  """
  def ale_state(rig_id) do
    Link.get_state(rig_id)
  end

  @doc """
  Transmit raw ALE symbols (for testing).
  """
  def ale_transmit(rig_id, symbols) do
    Transmitter.transmit(rig_id, symbols)
  end

  # --- Convenience: Create a test rig ---

  @doc """
  Create and start a test rig for development/testing.
  Returns the rig ID.
  """
  def create_test_rig(name \\ "Test Rig", opts \\ []) do
    self_addr = Keyword.get(opts, :self_addr, 0x1234)

    {:ok, rig} =
      Rigs.create_rig(%{
        name: name,
        rig_type: "test",
        protocol_stack: "ale_4g",
        self_addr: self_addr,
        enabled: true,
        control_type: "simulator",
        control_config: %{},
        rx_audio: "test_rx",
        tx_audio: "test_tx"
      })

    {:ok, _pid} = start(rig)
    {:ok, rig.id}
  end
end
