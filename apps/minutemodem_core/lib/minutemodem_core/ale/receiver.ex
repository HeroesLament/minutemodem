defmodule MinuteModemCore.ALE.Receiver do
  @moduledoc """
  ALE 4G Receiver - demodulates audio and decodes PDUs.

  Receives audio samples from Rig.Audio (which gets them from
  SimnetBridge for simnet rigs, or from the soundcard for physical rigs),
  demodulates to symbols, decodes frames, and dispatches PDUs to the Link FSM.

  ## Waveform Support

  Supports both Deep WALE and Fast WALE:
  - Deep WALE: Walsh-16 data modulation, 576-symbol preamble, ~150 bps
  - Fast WALE: BPSK data with interleaved probes, 288-symbol preamble, ~2400 bps

  ## Demodulator Architecture

  The PSK8 demodulator includes an 8th-power PLL for carrier tracking that
  updates INSIDE the sample loop. This allows tracking phase drift over long
  frames (e.g., 2.8s ALE Deep WALE with 0.12Hz Doppler = 120° drift).

  For each new transmission (large sample batch), we:
  1. Reset the demodulator for clean acquisition
  2. Demodulate in a single pass - PLL tracks phase throughout
  3. Find capture probe and resolve 45° ambiguity
  4. Decode frame directly from symbols

  No re-demodulation is needed since the PLL maintains phase coherence.
  """

  use GenServer
  require Logger

  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.ALE.{Decoding, Encoding, Link, PDU}
  alias MinuteModemCore.ALE.Waveform
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, Walsh}
  alias MinuteModemCore.Rig.Audio

  defstruct [
    :rig_id,
    :sample_rate,
    :demod,
    :symbol_buffer,
    :frame_sync_state
  ]

  @sample_rate 9600
  @samples_per_symbol 4  # 9600 / 2400 = 4
  @full_probe_length 96

  # Deep WALE frame structure
  @deep_preamble_symbols 576   # 18 Walsh blocks × 32 symbols
  @deep_data_symbols 6144      # 96 quadbits × 64 symbols (Walsh-16)

  # Fast WALE frame structure
  @fast_preamble_symbols 288   # 9 Walsh blocks × 32 symbols
  @fast_initial_probe 32       # Known probe before data

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :ale_receiver}}}
  end

  @doc """
  Feed audio samples to the receiver.
  Called by the audio pipeline when RX audio is available.
  """
  def rx_audio(rig_id, samples) when is_binary(samples) do
    sample_list = for <<s::signed-little-16 <- samples>>, do: s
    rx_audio(rig_id, sample_list)
  end

  def rx_audio(rig_id, samples) when is_list(samples) do
    GenServer.cast(via(rig_id), {:rx_audio, samples})
  end

  ## ------------------------------------------------------------------
  ## GenServer Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    sample_rate = Keyword.get(opts, :sample_rate, @sample_rate)

    Logger.info("ALE Receiver starting for rig #{rig_id} @ #{sample_rate}Hz")

    demod = PhyModem.unified_demod_new(:psk8, sample_rate)

    state = %__MODULE__{
      rig_id: rig_id,
      sample_rate: sample_rate,
      demod: demod,
      symbol_buffer: [],
      frame_sync_state: :searching
    }

    # Subscribe to RX audio from Rig.Audio
    {:ok, state, {:continue, :subscribe_audio}}
  end

  @impl true
  def handle_continue(:subscribe_audio, state) do
    case Audio.subscribe(state.rig_id) do
      :ok ->
        Logger.debug("ALE Receiver [#{state.rig_id}] subscribed to Rig.Audio")
      {:error, reason} ->
        Logger.warning("ALE Receiver [#{state.rig_id}] failed to subscribe: #{inspect(reason)}")
        # Retry after a delay
        Process.send_after(self(), :retry_subscribe, 500)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    case Audio.subscribe(state.rig_id) do
      :ok ->
        Logger.debug("ALE Receiver [#{state.rig_id}] subscribed to Rig.Audio (retry)")
      {:error, _} ->
        Process.send_after(self(), :retry_subscribe, 500)
    end
    {:noreply, state}
  end

  # Handle RX audio from Rig.Audio (basic format)
  @impl true
  def handle_info({:rx_audio, _rig_id, samples}, state) do
    process_rx_samples(samples, state)
  end

  # Handle RX audio from Rig.Audio with metadata (simnet)
  @impl true
  def handle_info({:rx_audio, _rig_id, samples, metadata}, state) do
    Logger.debug("ALE RX [#{state.rig_id}] received #{length(samples)} samples from #{inspect(metadata[:from])}")
    process_rx_samples(samples, state)
  end

  @impl true
  def handle_cast({:rx_audio, samples}, state) do
    process_rx_samples(samples, state)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ALE Receiver [#{state.rig_id}] unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  ## ------------------------------------------------------------------
  ## Audio Processing
  ## ------------------------------------------------------------------

  defp process_rx_samples(samples, state) when is_binary(samples) do
    sample_list = for <<s::signed-little-16 <- samples>>, do: s
    process_rx_samples(sample_list, state)
  end

  defp process_rx_samples(samples, state) when is_list(samples) do
    # Apply AGC to prevent clipping from corrupting demodulation
    samples = apply_agc(samples)

    # For large sample batches (likely a complete transmission),
    # reset the demodulator for clean PLL acquisition
    state = if length(samples) > 1000 do
      PhyModem.unified_demod_reset(state.demod)
      %{state | symbol_buffer: []}
    else
      state
    end

    # Demodulate samples to symbols
    # With the fixed PLL, phase tracking happens inside the sample loop,
    # so symbols will maintain phase coherence through the entire frame
    symbols = PhyModem.unified_demod_symbols(state.demod, samples)

    # Add to buffer and try to find/decode frames
    new_state = process_symbols(state, symbols)

    {:noreply, new_state}
  end

  # Simple AGC: normalize samples to prevent clipping
  # Target peak amplitude of ~20000 (leaves headroom below 32767)
  @agc_target_peak 20000

  defp apply_agc(samples) when length(samples) < 100, do: samples

  defp apply_agc(samples) do
    peak = samples |> Enum.map(&abs/1) |> Enum.max()

    if peak > @agc_target_peak do
      scale = @agc_target_peak / peak
      Enum.map(samples, fn s -> round(s * scale) end)
    else
      samples
    end
  end

  ## ------------------------------------------------------------------
  ## Frame Processing
  ## ------------------------------------------------------------------

  defp process_symbols(state, []), do: state

  defp process_symbols(state, new_symbols) do
    buffer = state.symbol_buffer ++ new_symbols

    {remaining, decoded_pdus, state} = find_frames(buffer, state)

    Enum.each(decoded_pdus, fn pdu ->
      Logger.info("ALE RX [#{state.rig_id}] decoded PDU: #{inspect(pdu)}")
      Link.rx_pdu(state.rig_id, pdu)
    end)

    trimmed = if length(remaining) > 1000, do: Enum.take(remaining, -500), else: remaining

    %{state | symbol_buffer: trimmed}
  end

  defp find_frames(symbols, state) do
    case find_capture_probe(symbols) do
      {:found, offset, _rest, phase_info} ->
        Logger.debug("[ALE RX] Found capture probe at offset #{offset}, phase correction: #{phase_info.offset * 45}° (corr=#{phase_info.correlation})")

        # With the fixed PLL, symbols already have good phase coherence.
        # No re-demodulation needed - work directly with these symbols.

        # Get frame symbols after probe
        frame_start = offset + @full_probe_length
        frame_symbols = Enum.drop(symbols, frame_start)

        # Debug: show raw first 32 symbols (before phase correction)
        raw_first_32 = Enum.take(frame_symbols, 32)
        Logger.debug("[ALE RX] Raw first 32 symbols: #{inspect(raw_first_32)}")

        # BPSK probe correlation only determines phase mod 4 (0-3 vs 4-7 ambiguity)
        # We need to try all phases and find the one that decodes the preamble correctly
        # The first Walsh block should decode to dibit 0 (all zeros after descramble)
        phase_scores = Enum.map(0..7, fn phase ->
          corrected = Enum.map(frame_symbols, fn s -> rem(s - phase + 8, 8) end)
          first_block = Enum.take(corrected, 32)

          # Descramble and count zeros (dibit 0 = all zeros)
          descrambled = Walsh.descramble_preamble(first_block)
          zeros = Enum.count(descrambled, &(&1 == 0))

          # Also check if waveform detection works
          waveform_score = case Waveform.detect_waveform(corrected) do
            {:ok, _, %{correlation_score: score}} -> score
            _ -> -1000
          end

          {phase, zeros, waveform_score}
        end)

        # Log all scores for debugging
        scores_str = Enum.map(phase_scores, fn {p, z, w} -> "#{p}:#{z}/#{w}" end) |> Enum.join(" ")
        Logger.debug("[ALE RX] Phase scores (phase:zeros/waveform): #{scores_str}")

        # Pick best phase by zeros count (primary) and waveform score (secondary)
        {best_phase, best_zeros, _waveform} = Enum.max_by(phase_scores, fn {_p, z, w} -> {z, w} end)

        Logger.debug("[ALE RX] Best phase: #{best_phase} (#{best_phase * 45}°) with #{best_zeros} zeros")

        corrected = Enum.map(frame_symbols, fn s ->
          rem(s - best_phase + 8, 8)
        end)

        Logger.debug("[ALE RX] Refined phase: #{best_phase * 45}°")

        case decode_frame(corrected) do
          {:ok, pdu, remaining} ->
            {final_remaining, more_pdus, final_state} = find_frames(remaining, state)
            {final_remaining, [pdu | more_pdus], final_state}

          :incomplete ->
            {[], [], state}

          :error ->
            Logger.debug("[ALE RX] Frame decode failed")
            {[], [], state}
        end

      :not_found ->
        {symbols, [], state}
    end
  end

  # Use the actual capture probe from the Walsh module (96 symbols)
  # For efficiency, we correlate against the first 32 symbols
  @capture_probe_prefix Enum.take(MinuteModemCore.ALE.Waveform.Walsh.capture_probe(), 32)
  @probe_length 32

  defp find_capture_probe(symbols) when length(symbols) < @full_probe_length do
    :not_found
  end

  defp find_capture_probe(symbols) do
    find_probe_at(symbols, 0)
  end

  defp find_probe_at(symbols, offset) when length(symbols) - offset < @full_probe_length do
    :not_found
  end

  defp find_probe_at(symbols, offset) do
    window = Enum.slice(symbols, offset, @probe_length)

    # Try all 8 possible phase offsets and find the best correlation
    {best_offset, best_corr} = find_best_phase_offset(window, @capture_probe_prefix)

    if abs(best_corr) > 24 do
      # Found probe with phase offset
      # Determine if we need 180° inversion on top of the rotation
      phase_correction = if best_corr > 0, do: best_offset, else: rem(best_offset + 4, 8)

      phase_info = %{offset: phase_correction, correlation: best_corr}
      {:found, offset, nil, phase_info}
    else
      find_probe_at(symbols, offset + 1)
    end
  end

  # Try all 8 phase offsets and return the one with highest |correlation|
  defp find_best_phase_offset(received, reference) do
    0..7
    |> Enum.map(fn phase_offset ->
      # Rotate received symbols by -phase_offset
      rotated = Enum.map(received, fn s -> rem(s - phase_offset + 8, 8) end)
      corr = correlate_bpsk(rotated, reference)
      {phase_offset, corr}
    end)
    |> Enum.max_by(fn {_offset, corr} -> abs(corr) end)
  end

  # BPSK correlation: 0-3 → +1, 4-7 → -1
  defp correlate_bpsk(received, reference) do
    Enum.zip(received, reference)
    |> Enum.reduce(0, fn {r, ref}, acc ->
      r_sign = if r < 4, do: 1, else: -1
      ref_sign = if ref < 4, do: 1, else: -1
      acc + r_sign * ref_sign
    end)
  end

  defp decode_frame(symbols) when length(symbols) < @deep_preamble_symbols do
    :incomplete
  end

  defp decode_frame(symbols) do
    # Detect waveform type from preamble
    case Waveform.detect_waveform(symbols) do
      {:ok, :deep, preamble_info} ->
        Logger.debug("[ALE RX] Detected Deep WALE, more_pdus=#{preamble_info.more_pdus}")
        decode_deep_wale_frame(symbols)

      {:ok, :fast, preamble_info} ->
        Logger.debug("[ALE RX] Detected Fast WALE, more_pdus=#{preamble_info.more_pdus}")
        decode_fast_wale_frame(symbols)

      {:error, reason} ->
        Logger.debug("[ALE RX] Waveform detection failed: #{inspect(reason)}")
        :error
    end
  end

  # Decode Deep WALE frame
  # Structure: [Preamble: 576] [Data: 6144]
  defp decode_deep_wale_frame(symbols) do
    # Skip preamble, get data symbols
    data_start = @deep_preamble_symbols
    data_symbols = Enum.slice(symbols, data_start, @deep_data_symbols)

    # Allow up to 64 missing symbols (1 Walsh-16 block) and pad with zeros
    min_data_symbols = @deep_data_symbols - 64

    if length(data_symbols) < min_data_symbols do
      Logger.debug("[ALE RX] Deep WALE incomplete: #{length(data_symbols)} < #{min_data_symbols}")
      :incomplete
    else
      # === Phase coherence - compare first vs last PREAMBLE block ===
      # Preamble is 576 symbols = 18 Walsh blocks × 32 symbols
      # Both blocks should descramble to zeros if PLL maintains lock
      first_preamble_block = Enum.take(symbols, 32)                    # Block 1: symbols 0-31
      last_preamble_block = Enum.slice(symbols, 544, 32)               # Block 18: symbols 544-575
      first_descrambled = Walsh.descramble_preamble(first_preamble_block)
      last_descrambled = Walsh.descramble_preamble(last_preamble_block)
      first_zeros = Enum.count(first_descrambled, &(&1 == 0))
      last_zeros = Enum.count(last_descrambled, &(&1 == 0))
      Logger.debug("[ALE RX] Phase coherence: preamble_start=#{first_zeros}/32, preamble_end=#{last_zeros}/32")

      # Pad to full size if slightly short
      data_symbols = if length(data_symbols) < @deep_data_symbols do
        data_symbols ++ List.duplicate(0, @deep_data_symbols - length(data_symbols))
      else
        data_symbols
      end
      # Decode through Deep WALE path:
      # 1. Descramble + Walsh-16 correlate -> dibits (interleaved)
      {dibits, _scrambler} = DeepWale.decode_data(data_symbols)

      # 2. Deinterleave
      deinterleaved = Encoding.deinterleave(dibits, 12, 16)

      # 3. Viterbi decode
      case viterbi_decode(deinterleaved) do
        {:ok, decoded_bits} ->
          # === DEBUG 2: Show Viterbi output ===
          decoded_bytes = bits_to_bytes(Enum.drop(decoded_bits, -6))
          Logger.debug("[ALE RX] Viterbi: #{length(decoded_bits)} bits -> #{length(decoded_bytes)} bytes, first 12: #{inspect(Enum.take(decoded_bytes, 12))}")

          # 4. Parse PDU from bits
          case bits_to_pdu(decoded_bits) do
            {:ok, pdu} ->
              remaining = Enum.drop(symbols, data_start + @deep_data_symbols)
              {:ok, pdu, remaining}
            {:error, reason} ->
              # === DEBUG 3: Show expected vs actual on CRC failure ===
              type_names = %{0x68 => "LsuReq", 0x69 => "LsuConf", 0x6A => "LsuTerm"}
              first_byte = List.first(decoded_bytes) || 0
              type_name = Map.get(type_names, first_byte, "Unknown(0x#{Integer.to_string(first_byte, 16)})")
              Logger.debug("[ALE RX] PDU parse failed: #{inspect(reason)}, type=#{type_name}")
              :error
          end

        {:error, reason} ->
          Logger.debug("[ALE RX] Viterbi decode failed: #{inspect(reason)}")
          :error
      end
    end
  end

  # Decode Fast WALE frame
  # Structure: [Preamble: 288] [K: 32] [U: 96] [K: 32] [U: 96]...
  defp decode_fast_wale_frame(symbols) do
    # Skip preamble and initial probe
    data_start = @fast_preamble_symbols + @fast_initial_probe
    data_symbols = Enum.drop(symbols, data_start)

    # === Phase coherence for Fast WALE ===
    # Preamble is 288 symbols = 9 Walsh blocks × 32 symbols
    first_preamble_block = Enum.take(symbols, 32)                    # Block 1: symbols 0-31
    last_preamble_block = Enum.slice(symbols, 256, 32)               # Block 9: symbols 256-287
    first_descrambled = Walsh.descramble_preamble(first_preamble_block)
    last_descrambled = Walsh.descramble_preamble(last_preamble_block)
    first_zeros = Enum.count(first_descrambled, &(&1 == 0))
    last_zeros = Enum.count(last_descrambled, &(&1 == 0))
    Logger.debug("[ALE RX] Fast phase coherence: preamble_start=#{first_zeros}/32, preamble_end=#{last_zeros}/32")

    # Decode through Fast WALE path
    dibits = FastWale.decode_data(data_symbols)

    # Deinterleave
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)

    # Viterbi decode
    case viterbi_decode(deinterleaved) do
      {:ok, decoded_bits} ->
        decoded_bytes = bits_to_bytes(Enum.drop(decoded_bits, -6))
        Logger.debug("[ALE RX] Fast Viterbi: #{length(decoded_bytes)} bytes, first 12: #{inspect(Enum.take(decoded_bytes, 12))}")

        case bits_to_pdu(decoded_bits) do
          {:ok, pdu} ->
            # Estimate consumed symbols (data + probes)
            # Each 128-symbol block = 96 data + 32 probe
            num_blocks = div(length(dibits) * 2 + 127, 128)
            consumed = data_start + num_blocks * 128
            remaining = Enum.drop(symbols, consumed)
            {:ok, pdu, remaining}
          {:error, reason} ->
            type_names = %{0x68 => "LsuReq", 0x69 => "LsuConf", 0x6A => "LsuTerm"}
            first_byte = List.first(decoded_bytes) || 0
            type_name = Map.get(type_names, first_byte, "Unknown(0x#{Integer.to_string(first_byte, 16)})")
            Logger.debug("[ALE RX] Fast PDU failed: #{inspect(reason)}, type=#{type_name}")
            :error
        end

      {:error, reason} ->
        Logger.debug("[ALE RX] Viterbi decode failed: #{inspect(reason)}")
        :error
    end
  end

  ## ------------------------------------------------------------------
  ## Viterbi Decoder (rate 1/2, K=7)
  ## ------------------------------------------------------------------

  # Generator polynomials (same as Encoding/Decoding modules)
  @g1 0b1011011
  @g2 0b1111001
  @num_states 64  # 2^(K-1)

  import Bitwise

  defp viterbi_decode(dibits) do
    # Initialize path metrics - state 0 starts at 0, others at infinity
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    # Process each dibit
    {_final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    # Traceback from state 0 (assumes encoder flushed to zero state)
    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()

    {:ok, decoded}
  end

  defp viterbi_step(metrics, paths, received_dibit) do
    # Convert dibit to bit pair
    received = {band(bsr(received_dibit, 1), 1), band(received_dibit, 1)}

    # For each state, find best predecessor
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = band(next_state, 1)
        prev_state = bsr(next_state, 1)
        prev_state_alt = bor(prev_state, 0x20)

        # Expected outputs for each transition
        exp = expected_output(prev_state, input_bit)
        exp_alt = expected_output(prev_state_alt, input_bit)

        # Branch metrics (Hamming distance)
        bm = hamming_distance(exp, received)
        bm_alt = hamming_distance(exp_alt, received)

        # Path metrics
        pm = Map.get(metrics, prev_state, 10000) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 10000) + bm_alt

        # Select survivor
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
    new_reg = bor(bsl(state, 1), input_bit)
    out1 = parity(band(new_reg, @g1))
    out2 = parity(band(new_reg, @g2))
    {out1, out2}
  end

  defp parity(x) do
    x
    |> Integer.digits(2)
    |> Enum.sum()
    |> rem(2)
  end

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  ## ------------------------------------------------------------------
  ## PDU Parsing
  ## ------------------------------------------------------------------

  defp bits_to_pdu(bits) do
    # Remove flush bits (last 6 bits from encoder flush)
    data_bits = Enum.drop(bits, -6)

    # Convert bits to bytes
    bytes = bits_to_bytes(data_bits)

    # Need exactly 12 bytes for PDU
    if length(bytes) >= 12 do
      pdu_bytes = Enum.take(bytes, 12) |> :erlang.list_to_binary()
      PDU.decode(pdu_bytes)
    else
      {:error, :invalid_length}
    end
  end

  defp bits_to_bytes(bits) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(fn chunk -> length(chunk) == 8 end)
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        bor(acc, bsl(bit, 7 - idx))
      end)
    end)
  end
end
