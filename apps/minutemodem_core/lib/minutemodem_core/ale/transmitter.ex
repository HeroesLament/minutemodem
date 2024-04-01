defmodule MinuteModemCore.ALE.Transmitter do
  @moduledoc """
  Bridges the ALE Link state machine to the audio output.

  Takes symbol streams from the Link FSM, modulates them via the
  PHY modem NIF, and pushes audio samples to the rig's audio pipeline.

  Routes audio through Modem.Events so Rig.AudioPipeline can decide
  where to send it (speakers for physical rigs, simnet for test rigs).

  Each rig has one Transmitter instance.
  """

  use GenServer

  require Logger

  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Modem.Events

  @default_sample_rate 9600

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :ale_tx}}}
  end

  @doc """
  Transmit a list of symbols.

  Modulates the symbols and sends audio to the rig's TX pipeline.
  Returns when transmission is complete.
  """
  @spec transmit(term(), [0..7]) :: :ok | {:error, term()}
  def transmit(rig_id, symbols) when is_list(symbols) do
    GenServer.call(via(rig_id), {:transmit, symbols}, :infinity)
  end

  @doc """
  Get the current transmitter state.
  """
  @spec get_state(term()) :: :idle | :transmitting
  def get_state(rig_id) do
    GenServer.call(via(rig_id), :get_state)
  end

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)

    Logger.info("ALE Transmitter starting for rig #{rig_id} @ #{sample_rate}Hz")

    modulator = PhyModem.unified_mod_new(:psk8, sample_rate)

    state = %{
      rig_id: rig_id,
      sample_rate: sample_rate,
      modulator: modulator,
      tx_state: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:transmit, symbols}, _from, state) do
    Logger.debug("ALE TX [#{state.rig_id}] transmitting #{length(symbols)} symbols")

    samples = PhyModem.unified_mod_modulate(state.modulator, symbols)
    tail = PhyModem.unified_mod_flush(state.modulator)
    all_samples = samples ++ tail

    PhyModem.unified_mod_reset(state.modulator)

    duration_ms = length(all_samples) / state.sample_rate * 1000
    Logger.debug("ALE TX [#{state.rig_id}] #{length(all_samples)} samples, #{round(duration_ms)}ms")

    result = send_to_audio_pipeline(state.rig_id, all_samples, state.sample_rate)

    broadcast_tx_event(state.rig_id, length(symbols), length(all_samples), duration_ms)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.tx_state, state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp send_to_audio_pipeline(rig_id, samples, _sample_rate) do
    # Convert samples to binary (s16le)
    binary =
      samples
      |> Enum.map(fn s ->
        clamped = max(-32768, min(32767, round(s)))
        <<clamped::little-signed-16>>
      end)
      |> IO.iodata_to_binary()

    # Broadcast through Modem.Events - AudioPipeline will receive and route appropriately
    Events.broadcast(rig_id, {:modem, {:tx_audio, binary}})

    Logger.debug("ALE TX [#{rig_id}] sent #{byte_size(binary)} bytes to Modem.Events")

    # Also broadcast to pg subscribers (for loopback testing, etc)
    broadcast(rig_id, {:tx_audio, rig_id, binary, _sample_rate})

    # Write debug file if configured
    if Application.get_env(:minutemodem_core, :debug_tx_audio, false) do
      write_debug_wav(rig_id, binary, _sample_rate)
    end

    :ok
  rescue
    e ->
      Logger.error("ALE TX [#{rig_id}] failed to send audio: #{inspect(e)}")
      {:error, e}
  end

  defp write_debug_wav(rig_id, binary, sample_rate) do
    byte_rate = sample_rate * 2
    size = byte_size(binary)

    wav_header = <<
      "RIFF",
      (size + 36)::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      1::little-16,
      1::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      2::little-16,
      16::little-16,
      "data",
      size::little-32
    >>

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = "/tmp/ale_tx_#{rig_id}_#{timestamp}.wav"
    File.write!(filename, wav_header <> binary)
    Logger.debug("ALE TX [#{rig_id}] wrote debug WAV: #{filename}")
  end

  defp broadcast_tx_event(rig_id, symbol_count, sample_count, duration_ms) do
    broadcast(rig_id, {:ale_tx, rig_id, %{
      symbols: symbol_count,
      samples: sample_count,
      duration_ms: duration_ms
    }})
  end

  defp broadcast(rig_id, message) do
    group = {:minutemodem, :rig, rig_id}
    for pid <- :pg.get_members(:minutemodem_pg, group) do
      send(pid, message)
    end
    :ok
  rescue
    _ -> :ok
  end
end
