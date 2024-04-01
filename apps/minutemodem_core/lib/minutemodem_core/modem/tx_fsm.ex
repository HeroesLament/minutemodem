defmodule MinuteModemCore.Modem.TxFSM do
  @moduledoc """
  Transmitter finite state machine.

  Wraps `Modem110D.Tx` and `Modem110D.Codec` to provide DTE-level states
  per MIL-STD-188-110D Appendix A Figure A-9.

  ## DTE States

  - `:flushed` - Idle, queues empty, ready to arm
  - `:armed_port_not_ready` - Armed but blocked (half-duplex RX in progress)
  - `:armed_port_ready` - Armed and ready for prefill data
  - `:ready_to_start` - Prefill complete, waiting for START
  - `:started` - Actively transmitting
  - `:draining_ok` - LAST received, draining normally
  - `:draining_forced` - Underrun or abort, draining with error

  ## Data Flow

      Interface (DTE packets)
           │
           │ tx_data(binary)
           ▼
       TxFSM (this module)
           │
           │ Accumulate → Codec.encode → Tx.transmit
           ▼
       Audio samples
           │
           ▼
       AudioPipeline

  ## Encoding Pipeline

  When START is issued:
  1. Collect all queued data
  2. Pass through Modem110D.Codec (FEC, interleave, symbol map, scramble)
  3. Pass through Modem110D.Tx (preamble, framing, modulation)
  4. Send audio to AudioPipeline
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger
  import Bitwise

  alias MinuteModemCore.Modem.{Events, Arbiter}
  alias MinuteModemCore.Modem110D.{Tx, Codec, Tables, Waveforms}

  # ============================================================================
  # State Data
  # ============================================================================

  defstruct [
    :rig_id,
    # Waveform configuration
    :waveform,         # waveform number (1-12)
    :bw_khz,           # bandwidth
    :interleaver,      # :ultra_short, :short, :medium, :long
    :constraint_length, # 7 or 9
    :sample_rate,      # audio sample rate
    # DTE-reported parameters
    :data_rate,        # bits per second
    :blocking_factor,  # bits per interleaver block
    # Queue state
    :queue,            # :queue of {data, order} tuples
    :queued_bytes,     # total bytes in queue
    :max_queue_bytes,  # backpressure threshold
    # Prefill tracking
    :prefill_bytes,    # bytes needed before START
    :prefill_received, # bytes received since ARM
    # Timing (for underrun detection)
    :critical_bytes,   # minimum bytes before deadline
    :critical_ms,      # deadline in ms
    :critical_timer,   # timer reference for underrun detection
    # Current packet order tracking
    :seen_last,        # have we received a LAST/FIRST_AND_LAST?
    # Audio output callback
    :audio_sink,       # pid or function to receive audio samples
    # Simnet mode flag (synchronous audio delivery)
    :use_simnet        # true if audio delivery is synchronous (no drain needed)
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
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :tx}}}
  end

  @doc "Arm transmitter queues"
  def arm(server) do
    GenStateMachine.call(server, :arm)
  end

  @doc "Queue data for transmission"
  def data(server, payload, order) do
    GenStateMachine.call(server, {:data, payload, order})
  end

  @doc "Start transmission"
  def start(server) do
    GenStateMachine.call(server, :start)
  end

  @doc "Abort transmission"
  def abort(server) do
    GenStateMachine.cast(server, :abort)
  end

  @doc "Get current status"
  def status(server) do
    GenStateMachine.call(server, :status)
  end

  @doc "Update waveform parameters"
  def set_params(server, waveform, bw_khz, interleaver) do
    GenStateMachine.call(server, {:set_params, waveform, bw_khz, interleaver})
  end

  # ============================================================================
  # Initialization
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    # Set rig identifier for all log messages from this process
    Logger.metadata(rig: String.slice(rig_id, 0, 8))

    # Waveform configuration
    waveform = Keyword.get(opts, :waveform, 1)
    bw_khz = Keyword.get(opts, :bw_khz, 3)
    interleaver = Keyword.get(opts, :interleaver, :short)
    constraint_length = Keyword.get(opts, :constraint_length, 7)
    sample_rate = Keyword.get(opts, :sample_rate, 48000)

    # Check if using simnet (synchronous audio - no drain wait needed)
    rig_type = Keyword.get(opts, :rig_type, "physical")
    use_simnet = rig_type in ["test", "simulator"]

    # Calculate DTE parameters from waveform
    data_rate = calculate_data_rate(waveform, bw_khz)
    blocking_factor = calculate_blocking_factor(waveform, bw_khz)

    # Calculate prefill requirement: 3 blocking factors in bytes
    prefill_bytes = div(3 * blocking_factor, 8)

    data = %__MODULE__{
      rig_id: rig_id,
      waveform: waveform,
      bw_khz: bw_khz,
      interleaver: interleaver,
      constraint_length: constraint_length,
      sample_rate: sample_rate,
      data_rate: data_rate,
      blocking_factor: blocking_factor,
      queue: :queue.new(),
      queued_bytes: 0,
      max_queue_bytes: 65536,  # 64KB default
      prefill_bytes: prefill_bytes,
      prefill_received: 0,
      critical_bytes: 0,
      critical_ms: 0,
      critical_timer: nil,
      seen_last: false,
      audio_sink: Keyword.get(opts, :audio_sink),
      use_simnet: use_simnet
    }

    Logger.info("[Modem.TxFSM] Started for rig #{rig_id}, wf=#{waveform}, bw=#{bw_khz}kHz, rate=#{data_rate}bps")

    {:ok, :flushed, data}
  end

  defp bits_per_symbol(waveform) do
    case Tables.modulation(waveform) do
      :bpsk -> 1
      :qpsk -> 2
      :psk8 -> 3
      :qam16 -> 4
      :qam32 -> 5
      :qam64 -> 6
      _ -> 3
    end
  end

  # ============================================================================
  # State: flushed
  # ============================================================================

  def flushed(:enter, _old_state, data) do
    # Notify subscribers
    emit_status(data, :flushed)
    {:keep_state, reset_for_new_tx(data)}
  end

  def flushed({:call, from}, :arm, data) do
    # Request permission from arbiter
    case Arbiter.request_tx(via_arbiter(data.rig_id)) do
      :ok ->
        {:next_state, :armed_port_ready, data, [{:reply, from, {:ok, :armed}}]}

      :port_not_ready ->
        {:next_state, :armed_port_not_ready, data, [{:reply, from, {:ok, :armed_port_not_ready}}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def flushed({:call, from}, {:data, _payload, _order}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_armed}}]}
  end

  def flushed({:call, from}, :start, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_armed}}]}
  end

  def flushed({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :flushed)}]}
  end

  def flushed({:call, from}, {:set_params, rate, blocking}, data) do
    prefill_bytes = div(3 * blocking, 8)
    new_data = %{data | data_rate: rate, blocking_factor: blocking, prefill_bytes: prefill_bytes}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def flushed(:cast, :abort, _data) do
    # Already flushed, nothing to abort
    :keep_state_and_data
  end

  # ============================================================================
  # State: armed_port_not_ready (half-duplex, waiting for RX to complete)
  # ============================================================================

  def armed_port_not_ready(:enter, _old_state, data) do
    emit_status(data, :armed_port_not_ready)
    :keep_state_and_data
  end

  def armed_port_not_ready({:call, from}, {:data, payload, order}, data) do
    # Can queue data even when port not ready
    case queue_data(data, payload, order) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def armed_port_not_ready({:call, from}, :start, _data) do
    # Cannot start until port ready
    {:keep_state_and_data, [{:reply, from, {:error, :port_not_ready}}]}
  end

  def armed_port_not_ready({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :armed_port_not_ready)}]}
  end

  def armed_port_not_ready(:info, {:port_ready}, data) do
    # Arbiter says we can proceed
    {:next_state, :armed_port_ready, data}
  end

  def armed_port_not_ready(:cast, :abort, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  # ============================================================================
  # State: armed_port_ready
  # ============================================================================

  def armed_port_ready(:enter, _old_state, data) do
    emit_status(data, :armed_port_ready)
    :keep_state_and_data
  end

  # Already armed, just acknowledge
  def armed_port_ready({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :armed_port_ready}}]}
  end

  def armed_port_ready({:call, from}, {:data, payload, order}, data) do
    case queue_data(data, payload, order) do
      {:ok, new_data} ->
        # Check if we've met prefill requirement
        if new_data.prefill_received >= new_data.prefill_bytes or new_data.seen_last do
          {:next_state, :ready_to_start, new_data, [{:reply, from, :ok}]}
        else
          {:keep_state, new_data, [{:reply, from, :ok}]}
        end

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def armed_port_ready({:call, from}, :start, data) do
    # Can't start until prefill met (unless LAST already received)
    if data.prefill_received >= data.prefill_bytes or data.seen_last do
      {:next_state, :starting, data, [{:reply, from, {:ok, :starting}}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :insufficient_prefill}}]}
    end
  end

  def armed_port_ready({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :armed_port_ready)}]}
  end

  def armed_port_ready(:cast, :abort, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  # ============================================================================
  # State: ready_to_start (prefill complete, awaiting START command)
  # ============================================================================

  def ready_to_start(:enter, _old_state, data) do
    emit_status(data, :ready_to_start)
    :keep_state_and_data
  end

  # Already armed/ready, just acknowledge
  def ready_to_start({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :ready_to_start}}]}
  end

  def ready_to_start({:call, from}, {:data, payload, order}, data) do
    case queue_data(data, payload, order) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def ready_to_start({:call, from}, :start, data) do
    {:next_state, :starting, data, [{:reply, from, {:ok, :starting}}]}
  end

  def ready_to_start({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :ready_to_start)}]}
  end

  def ready_to_start(:cast, :abort, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  # ============================================================================
  # State: starting (START issued, encoding and transmitting)
  # ============================================================================

  def starting(:enter, _old_state, data) do
    emit_status(data, :starting)

    # Collect all queued data
    all_data = collect_queue_data(data.queue)

    Logger.info("[Modem.TxFSM] Starting transmission: #{byte_size(all_data)} bytes")

    # Encode and transmit - always succeeds with {:ok, samples}
    {:ok, audio_samples} = encode_and_transmit(all_data, data)

    # Send audio to sink
    send_audio(data, audio_samples)

    # Transition to started (will drain as audio plays)
    {:keep_state, data, [{:state_timeout, 100, :check_drain}]}
  end

  def starting({:call, from}, {:data, payload, order}, data) do
    # Can still queue more data while encoding
    case queue_data(data, payload, order) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def starting({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :transmitting}}]}
  end

  def starting({:call, from}, :start, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_starting}}]}
  end

  def starting({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :starting)}]}
  end

  def starting(:state_timeout, :check_drain, data) do
    # Transition to started - audio is playing
    {:next_state, :started, data}
  end

  def starting(:cast, :abort, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  defp encode_and_transmit(user_data, data) do
    # Convert bytes to bits
    data_bits = bytes_to_bits(user_data)

    # 1. Build WID-like params for codec
    codec_params = [
      waveform: data.waveform,
      constraint_length: data.constraint_length,
      interleaver: data.interleaver,
      rate: Waveforms.code_rate(data.waveform),
      bits_per_symbol: bits_per_symbol(data.waveform)
    ]

    # 2. Encode through codec (FEC, interleave, symbol map)
    {:ok, encoded_symbols} = Codec.encode(data_bits, codec_params, bandwidth: data.bw_khz)

    # 3. Transmit (preamble, framing, modulation)
    tx_opts = [
      waveform: data.waveform,
      bandwidth: data.bw_khz,
      interleaver: data.interleaver,
      constraint_length: data.constraint_length,
      sample_rate: data.sample_rate,
      tlc_blocks: 0,
      m: 1
    ]

    Tx.transmit(encoded_symbols, tx_opts)
  end

  defp bytes_to_bits(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn byte ->
      for i <- 7..0//-1, do: bsr(byte, i) |> band(1)
    end)
  end

  defp collect_queue_data(queue) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn {data, _order} -> data end)
    |> IO.iodata_to_binary()
  end

  defp send_audio(%{audio_sink: pid}, samples) when is_pid(pid) do
    send(pid, {:tx_audio, samples})
  end
  defp send_audio(%{audio_sink: fun}, samples) when is_function(fun, 1) do
    fun.(samples)
  end
  defp send_audio(%{rig_id: rig_id}, samples) do
    # Default: broadcast to AudioPipeline via Events
    Events.broadcast(rig_id, {:modem, {:tx_audio, samples}})
  end

  # ============================================================================
  # State: started (actively transmitting - audio playing)
  # ============================================================================

  def started(:enter, _old_state, data) do
    emit_status(data, :started)

    # If we already saw LAST during queueing, go straight to draining
    if data.seen_last do
      {:keep_state_and_data, [{:timeout, 0, :check_drain}]}
    else
      :keep_state_and_data
    end
  end

  def started(:timeout, :check_drain, data) do
    if data.seen_last do
      {:next_state, :draining_ok, data}
    else
      :keep_state_and_data
    end
  end

  def started({:call, from}, {:data, payload, order}, data) do
    case queue_data(data, payload, order) do
      {:ok, new_data} ->
        # Check if this was the last packet
        if order in [:last, :first_and_last] do
          {:next_state, :draining_ok, new_data, [{:reply, from, :ok}]}
        else
          {:keep_state, new_data, [{:reply, from, :ok}]}
        end

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def started({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :transmitting}}]}
  end

  def started({:call, from}, :start, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  def started({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :started)}]}
  end

  def started(:info, :tx_complete, data) do
    # Audio playback finished
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def started(:cast, :abort, data) do
    {:next_state, :draining_forced, data}
  end

  # ============================================================================
  # State: draining_ok (LAST received, normal drain)
  # ============================================================================

  def draining_ok(:enter, _old_state, data) do
    emit_status(data, :draining_ok)

    if data.use_simnet do
      # Simnet audio delivery is synchronous - no buffer to drain
      # Use immediate timeout to flush on next event loop iteration
      Logger.debug("[Modem.TxFSM] Simnet mode - immediate flush (no drain needed)")
      {:keep_state_and_data, [{:state_timeout, 0, :simnet_flush}]}
    else
      # Physical audio - wait for tx_complete or timeout
      {:keep_state_and_data, [{:state_timeout, 30_000, :drain_timeout}]}
    end
  end

  def draining_ok({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_ok({:call, from}, :start, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_ok({:call, from}, {:data, _payload, _order}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_ok({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :draining_ok)}]}
  end

  def draining_ok(:info, :tx_complete, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def draining_ok(:state_timeout, :simnet_flush, data) do
    # Simnet audio is synchronous - safe to flush immediately
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def draining_ok(:state_timeout, :drain_timeout, data) do
    # Audio should have finished by now
    Logger.warning("[Modem.TxFSM] Drain timeout, forcing flush")
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def draining_ok(:cast, :abort, data) do
    {:next_state, :draining_forced, data}
  end

  # ============================================================================
  # State: draining_forced (error/abort drain)
  # ============================================================================

  def draining_forced(:enter, _old_state, data) do
    emit_status(data, :draining_forced)
    emit_event(data.rig_id, :tx_underrun)
    # Short timeout then force flush
    {:keep_state_and_data, [{:state_timeout, 1_000, :force_flush}]}
  end

  def draining_forced({:call, from}, :arm, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_forced({:call, from}, :start, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_forced({:call, from}, {:data, _payload, _order}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  def draining_forced({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, build_status(data, :draining_forced)}]}
  end

  def draining_forced(:info, :tx_complete, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def draining_forced(:state_timeout, :force_flush, data) do
    Arbiter.release_tx(via_arbiter(data.rig_id))
    {:next_state, :flushed, data}
  end

  def draining_forced(:cast, :abort, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # Common handlers
  # ============================================================================

  @impl true
  def handle_event({:call, from}, :arm, state, _data) when state != :flushed do
    {:keep_state_and_data, [{:reply, from, {:error, :not_flushed}}]}
  end

  @impl true
  def handle_event({:call, from}, {:set_params, waveform, bw_khz, interleaver}, _state, data) do
    data_rate = calculate_data_rate(waveform, bw_khz)
    blocking_factor = calculate_blocking_factor(waveform, bw_khz)
    prefill_bytes = div(3 * blocking_factor, 8)

    new_data = %{data |
      waveform: waveform,
      bw_khz: bw_khz,
      interleaver: interleaver,
      data_rate: data_rate,
      blocking_factor: blocking_factor,
      prefill_bytes: prefill_bytes
    }

    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp reset_for_new_tx(data) do
    %{data |
      queue: :queue.new(),
      queued_bytes: 0,
      prefill_received: 0,
      seen_last: false,
      critical_timer: nil
    }
  end

  defp queue_data(data, payload, order) do
    bytes = byte_size(payload)

    if data.queued_bytes + bytes > data.max_queue_bytes do
      {:error, :queue_full}
    else
      new_queue = :queue.in({payload, order}, data.queue)
      seen_last = order in [:last, :first_and_last]

      {:ok, %{data |
        queue: new_queue,
        queued_bytes: data.queued_bytes + bytes,
        prefill_received: data.prefill_received + bytes,
        seen_last: data.seen_last or seen_last
      }}
    end
  end

  defp build_status(data, state) do
    %{
      state: state,
      queued_bytes: data.queued_bytes,
      free_bytes: data.max_queue_bytes - data.queued_bytes,
      data_rate: data.data_rate,
      blocking_factor: data.blocking_factor
    }
  end

  defp emit_status(data, state) do
    emit_event(data.rig_id, {:tx_status, build_status(data, state)})
  end

  defp emit_event(rig_id, event) do
    Events.broadcast(rig_id, {:modem, event})
  end

  defp via_arbiter(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :arbiter}}}
  end

  # Calculate data rate in bps from waveform and bandwidth
  # Based on MIL-STD-188-110D Table D-I
  defp calculate_data_rate(waveform, bw_khz) do
    base_rate = case waveform do
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

  # Calculate blocking factor in bits
  defp calculate_blocking_factor(waveform, bw_khz) do
    data_symbols = Tables.data_symbols(waveform, bw_khz)
    data_symbols * bits_per_symbol(waveform)
  end
end
