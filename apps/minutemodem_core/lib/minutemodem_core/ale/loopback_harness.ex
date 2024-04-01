defmodule MinuteModemCore.ALE.LoopbackHarness do
  @moduledoc """
  Test harness that creates a loopback between two ALE stations.

  Connects Transmitter audio output directly to the other station's Receiver,
  allowing end-to-end testing of the Link FSM handshake.

  Usage:
    {:ok, harness} = MinuteModemCore.ALE.LoopbackHarness.start()
    MinuteModemCore.ALE.LoopbackHarness.status(harness)

    # Station B scans
    MinuteModemCore.ALE.LoopbackHarness.scan(:b)

    # Station A calls Station B
    MinuteModemCore.ALE.LoopbackHarness.call(:a, :b)

    # Check link status
    MinuteModemCore.ALE.LoopbackHarness.status(harness)

    # Terminate
    MinuteModemCore.ALE.LoopbackHarness.terminate(:a)

    # Cleanup
    MinuteModemCore.ALE.LoopbackHarness.stop(harness)
  """

  use GenServer
  require Logger

  alias MinuteModemCore.ALE.{Link, PDU}
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, Walsh}
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600

  defstruct [
    :station_a,
    :station_b,
    :mod_a,
    :mod_b,
    :demod_a,
    :demod_b
  ]

  # Station configs
  @station_a %{id: "loopback-a", addr: 0x1234}
  @station_b %{id: "loopback-b", addr: 0x5678}

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start do
    GenServer.start(__MODULE__, [], name: __MODULE__)
  end

  def stop(harness \\ __MODULE__) do
    GenServer.stop(harness)
  end

  def status(harness \\ __MODULE__) do
    GenServer.call(harness, :status)
  end

  @doc "Start scanning on station :a or :b"
  def scan(station, opts \\ []) when station in [:a, :b] do
    GenServer.call(__MODULE__, {:scan, station, opts})
  end

  @doc "Station `from` calls station `to`"
  def call(from, to, opts \\ []) when from in [:a, :b] and to in [:a, :b] do
    GenServer.call(__MODULE__, {:call, from, to, opts})
  end

  @doc "Stop/cancel operation on station"
  def stop_station(station) when station in [:a, :b] do
    GenServer.call(__MODULE__, {:stop_station, station})
  end

  @doc "Terminate link on station"
  def terminate(station) when station in [:a, :b] do
    GenServer.call(__MODULE__, {:terminate, station})
  end

  @doc "Inject raw PDU to station's receiver"
  def inject_pdu(station, pdu) when station in [:a, :b] do
    GenServer.call(__MODULE__, {:inject_pdu, station, pdu})
  end

  ## ------------------------------------------------------------------
  ## GenServer Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.info("Starting ALE Loopback Harness...")

    # Start Link FSMs for both stations
    {:ok, _} = Link.start_link(rig_id: @station_a.id, self_addr: @station_a.addr)
    {:ok, _} = Link.start_link(rig_id: @station_b.id, self_addr: @station_b.addr)

    # Create unified modulators and demodulators
    mod_a = PhyModem.unified_mod_new(:psk8, @sample_rate)
    mod_b = PhyModem.unified_mod_new(:psk8, @sample_rate)
    demod_a = PhyModem.unified_demod_new(:psk8, @sample_rate)
    demod_b = PhyModem.unified_demod_new(:psk8, @sample_rate)

    # Subscribe to TX events from both stations
    :pg.join(:minutemodem_pg, {:minutemodem, :rig, @station_a.id}, self())
    :pg.join(:minutemodem_pg, {:minutemodem, :rig, @station_b.id}, self())

    state = %__MODULE__{
      station_a: @station_a,
      station_b: @station_b,
      mod_a: mod_a,
      mod_b: mod_b,
      demod_a: demod_a,
      demod_b: demod_b
    }

    Logger.info("Loopback Harness ready:")
    Logger.info("  Station A: #{@station_a.id} (0x#{Integer.to_string(@station_a.addr, 16)})")
    Logger.info("  Station B: #{@station_b.id} (0x#{Integer.to_string(@station_b.addr, 16)})")

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Stopping ALE Loopback Harness...")

    # Stop Link FSMs
    try do
      GenStateMachine.stop(Link.via(state.station_a.id), :normal)
    catch
      :exit, _ -> :ok
    end

    try do
      GenStateMachine.stop(Link.via(state.station_b.id), :normal)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    state_a = Link.get_state(state.station_a.id)
    state_b = Link.get_state(state.station_b.id)

    status = %{
      station_a: %{
        id: state.station_a.id,
        addr: "0x#{Integer.to_string(state.station_a.addr, 16)}",
        state: state_a
      },
      station_b: %{
        id: state.station_b.id,
        addr: "0x#{Integer.to_string(state.station_b.addr, 16)}",
        state: state_b
      }
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:scan, station, opts}, _from, state) do
    rig_id = get_rig_id(station, state)
    result = Link.scan(rig_id, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:call, from, to, opts}, _from, state) do
    from_id = get_rig_id(from, state)
    to_addr = get_addr(to, state)

    # Build the call with waveform and transmit via our loopback
    _waveform = Keyword.get(opts, :waveform, :fast)
    _tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)

    # Start the call in the Link FSM (it will try to TX but fail)
    # We intercept and do the actual TX ourselves
    result = Link.call(from_id, to_addr, opts)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:stop_station, station}, _from, state) do
    rig_id = get_rig_id(station, state)
    Link.stop(rig_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:terminate, station}, _from, state) do
    rig_id = get_rig_id(station, state)
    Link.terminate_link(rig_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:inject_pdu, station, pdu}, _from, state) do
    rig_id = get_rig_id(station, state)
    Link.rx_pdu(rig_id, pdu)
    {:reply, :ok, state}
  end

  # Handle TX symbols events - modulate, loopback, demodulate, deliver
  @impl true
  def handle_info({:ale_tx_symbols, rig_id, symbols}, state) do
    Logger.info("Loopback: TX #{length(symbols)} symbols from #{rig_id}")

    # Determine source and destination
    {_src_station, dest_station, mod, demod} =
      if rig_id == state.station_a.id do
        {:a, :b, state.mod_a, state.demod_b}
      else
        {:b, :a, state.mod_b, state.demod_a}
      end

    dest_rig_id = get_rig_id(dest_station, state)

    # Modulate symbols to audio
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    # Reset modulator for next use
    PhyModem.unified_mod_reset(mod)

    Logger.debug("Loopback: Modulated to #{length(all_samples)} samples")

    # Demodulate audio back to symbols
    rx_symbols = PhyModem.unified_demod_symbols(demod, all_samples)

    # Reset demodulator for next use
    PhyModem.unified_demod_reset(demod)

    Logger.debug("Loopback: Demodulated to #{length(rx_symbols)} symbols")

    # Decode and deliver PDU
    case decode_frame(rx_symbols) do
      {:ok, pdu} ->
        Logger.info("Loopback: Decoded PDU for station #{dest_station}: #{pdu.__struct__}")
        Link.rx_pdu(dest_rig_id, pdu)

      {:error, reason} ->
        Logger.warning("Loopback: Failed to decode frame: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Handle TX audio events (from real Transmitter, if running)
  @impl true
  def handle_info({:tx_audio, rig_id, binary, _sample_rate}, state) do
    Logger.debug("Loopback: TX audio from #{rig_id}, #{byte_size(binary)} bytes (ignored, using symbols)")
    {:noreply, state}
  end

  # Handle ALE events for logging
  @impl true
  def handle_info({:ale_state_change, rig_id, new_state, info}, state) do
    station = if rig_id == state.station_a.id, do: "A", else: "B"
    Logger.info("Loopback: Station #{station} -> #{new_state} #{inspect(info)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:ale_event, rig_id, event, payload}, state) do
    station = if rig_id == state.station_a.id, do: "A", else: "B"
    Logger.info("Loopback: Station #{station} event: #{event} #{inspect(payload)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:ale_tx, _rig_id, _info}, state) do
    # Already handled via :tx_audio
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Loopback: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## ------------------------------------------------------------------
  ## Frame Decoding
  ## ------------------------------------------------------------------

  # Decode received symbols into PDU
  defp decode_frame(symbols) do
    # Skip filter delay
    symbols = Enum.drop(symbols, 12)

    # Find capture probe and extract frame
    case find_frame_start(symbols) do
      {:ok, frame_symbols, waveform} ->
        decode_waveform_frame(frame_symbols, waveform)

      :not_found ->
        {:error, :no_frame_found}
    end
  end

  # Look for capture probe to find frame start
  defp find_frame_start(symbols) do
    capture_probe = Walsh.capture_probe()
    probe_len = length(capture_probe)

    # Simple correlation search
    case correlate_probe(symbols, capture_probe, 0) do
      {:found, offset} ->
        # Skip probe, detect waveform from preamble
        after_probe = Enum.drop(symbols, offset + probe_len)

        # Try to detect waveform type
        waveform = detect_waveform(after_probe)
        {:ok, after_probe, waveform}

      :not_found ->
        :not_found
    end
  end

  defp correlate_probe(_symbols, _probe, offset) when offset > 200 do
    :not_found
  end

  defp correlate_probe(symbols, probe, offset) do
    window = Enum.slice(symbols, offset, length(probe))

    if length(window) < length(probe) do
      :not_found
    else
      # BPSK correlation: 0,4 -> +1,-1
      correlation =
        Enum.zip(window, probe)
        |> Enum.map(fn {rx, exp} ->
          rx_sign = if rx in [0, 1, 2, 3], do: 1, else: -1
          exp_sign = if exp in [0, 1, 2, 3], do: 1, else: -1
          rx_sign * exp_sign
        end)
        |> Enum.sum()

      # High correlation = match
      if correlation > length(probe) * 0.7 do
        {:found, offset}
      else
        correlate_probe(symbols, probe, offset + 1)
      end
    end
  end

  defp detect_waveform(symbols) do
    # Check preamble length to determine waveform
    # Deep WALE: 576 symbols, Fast WALE: 288 symbols
    # For now, use a heuristic based on total frame length
    # or just try both decoders

    # Simple heuristic: if frame is very long, it's Deep WALE
    if length(symbols) > 2000 do
      :deep
    else
      :fast
    end
  end

  defp decode_waveform_frame(symbols, :deep) do
    # Skip preamble (576 symbols)
    data_symbols = Enum.drop(symbols, 576)

    # Decode Deep WALE data
    {dibits, _scrambler} = DeepWale.decode_data(data_symbols)

    # Deinterleave and Viterbi decode
    decode_dibits_to_pdu(dibits)
  end

  defp decode_waveform_frame(symbols, :fast) do
    # Skip preamble (288 symbols) and initial probe (32 symbols)
    data_symbols = Enum.drop(symbols, 288 + 32)

    # Decode Fast WALE data
    dibits = FastWale.decode_data(data_symbols)

    # Deinterleave and Viterbi decode
    decode_dibits_to_pdu(dibits)
  end

  # Viterbi decoder - same as in WaleLoopbackTest
  defp decode_dibits_to_pdu(dibits) do
    alias MinuteModemCore.ALE.Encoding

    # Deinterleave
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)

    # Viterbi decode
    case viterbi_decode(deinterleaved) do
      {:ok, bits} ->
        # Remove flush bits and convert to bytes
        data_bits = Enum.drop(bits, -6)
        bytes = bits_to_bytes(data_bits)

        if length(bytes) >= 12 do
          pdu_binary = bytes |> Enum.take(12) |> :erlang.list_to_binary()
          PDU.decode(pdu_binary)
        else
          {:error, :insufficient_bytes}
        end
    end
  end

  @g1 0b1011011
  @g2 0b1111001
  @num_states 64

  defp viterbi_decode(dibits) do
    import Bitwise

    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {_final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    {:ok, decoded}
  end

  defp viterbi_step(metrics, paths, received_dibit) do
    import Bitwise

    received = {Bitwise.bsr(received_dibit, 1) &&& 1, received_dibit &&& 1}

    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = next_state &&& 1
        prev_state = Bitwise.bsr(next_state, 1)
        prev_state_alt = prev_state ||| 0x20

        exp = expected_output(prev_state, input_bit)
        exp_alt = expected_output(prev_state_alt, input_bit)

        bm = hamming_distance(exp, received)
        bm_alt = hamming_distance(exp_alt, received)

        pm = Map.get(metrics, prev_state, 10000) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 10000) + bm_alt

        if pm <= pm_alt do
          prev_path = Map.get(paths, prev_state, [])
          {next_state, pm, [input_bit | prev_path]}
        else
          prev_path = Map.get(paths, prev_state_alt, [])
          {next_state, pm_alt, [input_bit | prev_path]}
        end
      end

    new_metrics = Map.new(new_state_data, fn {state, metric, _} -> {state, metric} end)
    new_paths = Map.new(new_state_data, fn {state, _, path} -> {state, path} end)

    {new_metrics, new_paths}
  end

  defp expected_output(state, input_bit) do
    import Bitwise
    new_reg = Bitwise.bsl(state, 1) ||| input_bit
    out1 = parity(new_reg &&& @g1)
    out2 = parity(new_reg &&& @g2)
    {out1, out2}
  end

  defp parity(x) do
    x |> Integer.digits(2) |> Enum.sum() |> rem(2)
  end

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  defp bits_to_bytes(bits) do
    import Bitwise
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(fn chunk -> length(chunk) == 8 end)
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        acc ||| Bitwise.bsl(bit, 7 - idx)
      end)
    end)
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp get_rig_id(:a, state), do: state.station_a.id
  defp get_rig_id(:b, state), do: state.station_b.id

  defp get_addr(:a, state), do: state.station_a.addr
  defp get_addr(:b, state), do: state.station_b.addr
end
