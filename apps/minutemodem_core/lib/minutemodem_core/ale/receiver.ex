defmodule MinuteModemCore.ALE.Receiver do
  @moduledoc """
  ALE 4G Receiver - demodulates audio and decodes PDUs.

  Receives audio samples from Rig.Audio (which gets them from
  SimnetBridge for simnet rigs, or from the soundcard for physical rigs),
  demodulates to symbols, decodes frames, and dispatches PDUs to the Link FSM.

  ## Streaming Architecture

  Audio may arrive in any chunk size — from complete transmissions (loopback
  testing) to small 192-sample ticks (simnet's 20ms epoch ticks). The receiver
  handles both transparently using energy-based signal detection:

  1. **Idle**: Measure RMS energy of incoming samples. When energy rises above
     the squelch threshold, transition to Receiving.

  2. **Receiving**: Reset the demodulator PLL for clean carrier acquisition,
     then demodulate all samples as they arrive, accumulating symbols.
     Continue until energy drops below threshold for several consecutive
     quiet chunks (end-of-transmission), or a maximum duration is reached.

  3. **Processing**: Once a complete transmission is captured, run frame
     detection and PDU decoding on the accumulated symbol buffer. Then
     return to Idle.

  This design is agnostic to chunk size: a single large batch triggers
  onset → accumulation → offset → decode in one pass, while many small
  ticks trigger the same sequence spread across multiple handle_info calls.

  ## Waveform Support

  Supports both Deep WALE and Fast WALE:
  - Deep WALE: Walsh-16 data modulation, 576-symbol preamble, ~150 bps
  - Fast WALE: BPSK data with interleaved probes, 288-symbol preamble, ~2400 bps

  ## Demodulator Architecture

  The PSK8 demodulator includes an 8th-power PLL for carrier tracking that
  updates INSIDE the sample loop. This allows tracking phase drift over long
  frames (e.g., 2.8s ALE Deep WALE with 0.12Hz Doppler = 120° drift).

  The PLL is reset at signal onset and then tracks phase continuously through
  the entire transmission, maintaining coherence across arbitrary chunk boundaries.
  """

  use GenServer
  require Logger

  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.ALE.{Decoding, Encoding, Link, LQA, PDU}
  alias MinuteModemCore.ALE.Waveform
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, Walsh}
  alias MinuteModemCore.Rig.{Audio, Control}

  @sample_rate 9600
  @samples_per_symbol 4  # 9600 / 2400 = 4
  @full_probe_length 96

  # Deep WALE frame structure
  @deep_preamble_symbols 576   # 18 Walsh blocks × 32 symbols
  @deep_data_symbols 6144      # 96 quadbits × 64 symbols (Walsh-16)

  # Fast WALE frame structure
  @fast_preamble_symbols 288   # 9 Walsh blocks × 32 symbols
  @fast_initial_probe 32       # Known probe before data

  # -------------------------------------------------------------------
  # Signal detection parameters
  # -------------------------------------------------------------------

  # RMS energy threshold to detect signal onset.
  # s16 noise floor is typically < 500 RMS; a modulated 8-PSK carrier
  # at reasonable SNR will be > 2000 RMS. We use 800 as a midpoint.
  @squelch_threshold 800

  # Number of consecutive quiet chunks below threshold before we declare
  # end-of-transmission. At 192 samples/chunk (20ms), 3 chunks = 60ms
  # of silence — enough gap to be confident the frame ended, but short
  # enough to not add latency.
  @quiet_chunks_for_eot 3

  # Maximum transmission duration in samples before we force processing.
  # Deep WALE is ~27k samples (~2.8s); allow 4s = 38400 samples.
  @max_tx_samples 38400

  # Minimum symbols required before attempting frame decode.
  # Capture probe (96) + Fast WALE preamble (288) + some data = ~500
  @min_symbols_for_decode 400

  # -------------------------------------------------------------------
  # State struct
  # -------------------------------------------------------------------

  defstruct [
    :rig_id,
    :sample_rate,
    :demod,
    rx_state: :idle,
    symbol_buffer: [],
    sample_buffer: [],
    rx_sample_count: 0,
    quiet_chunks: 0,
    noise_floor_rms: 200.0
  ]

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

  @doc """
  Check whether the receiver is currently detecting energy on the channel.

  Returns `true` if the receiver's squelch is open (signal detected or
  actively receiving), `false` if idle. Used by the Link FSM for LBT
  before sounding.

  Returns `false` if the receiver is not running.
  """
  def channel_busy?(rig_id) do
    GenServer.call(via(rig_id), :channel_busy?)
  catch
    :exit, _ -> false
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
      demod: demod
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
  def handle_info({:rx_audio, _rig_id, samples, _metadata}, state) do
    process_rx_samples(samples, state)
  end

  @impl true
  def handle_cast({:rx_audio, samples}, state) do
    process_rx_samples(samples, state)
  end

  @impl true
  def handle_call(:channel_busy?, _from, state) do
    {:reply, state.rx_state != :idle, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ALE Receiver [#{state.rig_id}] unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  ## ------------------------------------------------------------------
  ## Audio Processing — Signal Detection State Machine
  ## ------------------------------------------------------------------

  defp process_rx_samples(samples, state) when is_binary(samples) do
    sample_list = for <<s::signed-little-16 <- samples>>, do: s
    process_rx_samples(sample_list, state)
  end

  defp process_rx_samples([], state), do: {:noreply, state}

  defp process_rx_samples(samples, state) when is_list(samples) do
    # Compute RMS energy of this chunk for signal detection
    rms = compute_rms(samples)

    # Check if this is a large batch (e.g., loopback or file playback).
    # If so, handle the entire batch as one transmission — no need for
    # energy-based onset/offset detection.
    if length(samples) > 2000 do
      state = handle_large_batch(samples, state)
      {:noreply, state}
    else
      state = handle_streaming_chunk(samples, rms, state)
      {:noreply, state}
    end
  end

  # -------------------------------------------------------------------
  # Large batch path (loopback / file playback compatibility)
  # -------------------------------------------------------------------

  defp handle_large_batch(samples, state) do
    PhyModem.unified_demod_reset(state.demod)

    samples = apply_agc(samples)
    symbols = PhyModem.unified_demod_symbols(state.demod, samples)

    state = %{state |
      rx_state: :idle,
      symbol_buffer: [],
      sample_buffer: [],
      rx_sample_count: 0,
      quiet_chunks: 0
    }

    process_complete_frame(symbols, samples, state)
  end

  # -------------------------------------------------------------------
  # Streaming chunk path (simnet ticks, soundcard chunks)
  # -------------------------------------------------------------------

  defp handle_streaming_chunk(samples, rms, %{rx_state: :idle} = state) do
    signal_present = rms > effective_threshold(state)

    if signal_present do
      # === Signal onset detected ===
      threshold = effective_threshold(state)
      Logger.info("[ALE RX #{short(state.rig_id)}] Signal onset: RMS=#{round(rms)} threshold=#{round(threshold)} noise_floor=#{round(state.noise_floor_rms)}")

      :telemetry.execute(
        [:minutemodem, :ale, :signal_onset],
        %{rms: rms, threshold: threshold, noise_floor: state.noise_floor_rms},
        %{rig_id: state.rig_id}
      )

      # Notify the Link FSM so scanning can pause the dwell timer
      Link.signal_onset(state.rig_id)

      PhyModem.unified_demod_reset(state.demod)

      samples = apply_agc(samples)
      symbols = PhyModem.unified_demod_symbols(state.demod, samples)

      %{state |
        rx_state: :receiving,
        symbol_buffer: symbols,
        sample_buffer: samples,
        rx_sample_count: length(samples),
        quiet_chunks: 0
      }
    else
      # Update noise floor estimate (exponential moving average)
      # Only update when idle so active transmissions don't skew it
      alpha = 0.05
      new_floor = state.noise_floor_rms * (1.0 - alpha) + rms * alpha

      %{state | noise_floor_rms: new_floor}
    end
  end

  defp handle_streaming_chunk(samples, rms, %{rx_state: :receiving} = state) do
    signal_present = rms > effective_threshold(state)

    samples = apply_agc(samples)
    symbols = PhyModem.unified_demod_symbols(state.demod, samples)

    new_sample_count = state.rx_sample_count + length(samples)
    new_buffer = state.symbol_buffer ++ symbols
    new_sample_buffer = state.sample_buffer ++ samples

    new_state = cond do
      signal_present ->
        %{state |
          symbol_buffer: new_buffer,
          sample_buffer: new_sample_buffer,
          rx_sample_count: new_sample_count,
          quiet_chunks: 0
        }

      # Case 2: Signal dropped — increment quiet counter
      # We still demodulate these quiet chunks because the tail end of
      # the modulated signal may straddle the energy boundary
      state.quiet_chunks + 1 < @quiet_chunks_for_eot ->
        %{state |
          symbol_buffer: new_buffer,
          sample_buffer: new_sample_buffer,
          rx_sample_count: new_sample_count,
          quiet_chunks: state.quiet_chunks + 1
        }

      true ->
        Logger.info("[ALE RX #{short(state.rig_id)}] End of transmission: #{new_sample_count} samples, #{length(new_buffer)} symbols")

        :telemetry.execute(
          [:minutemodem, :ale, :signal_offset],
          %{
            sample_count: new_sample_count,
            symbol_count: length(new_buffer),
            duration_ms: new_sample_count / state.sample_rate * 1000.0
          },
          %{rig_id: state.rig_id}
        )

        # Notify the Link FSM that the signal has ended so scanning can resume
        Link.signal_offset(state.rig_id)

        reset_state = %{state |
          rx_state: :idle,
          symbol_buffer: [],
          sample_buffer: [],
          rx_sample_count: 0,
          quiet_chunks: 0
        }

        if length(new_buffer) >= @min_symbols_for_decode do
          process_complete_frame(new_buffer, new_sample_buffer, reset_state)
        else
          Logger.debug("[ALE RX #{short(state.rig_id)}] Too few symbols (#{length(new_buffer)}), discarding")
          reset_state
        end
    end

    maybe_force_process(new_state, new_buffer, new_sample_buffer)
  end

  defp maybe_force_process(%{rx_state: :receiving, rx_sample_count: count} = state, buffer, sample_buffer)
       when count >= @max_tx_samples do
    Logger.warning("[ALE RX #{short(state.rig_id)}] Max TX duration reached (#{count} samples), forcing decode")

    reset_state = %{state |
      rx_state: :idle,
      symbol_buffer: [],
      sample_buffer: [],
      rx_sample_count: 0,
      quiet_chunks: 0
    }

    if length(buffer) >= @min_symbols_for_decode do
      process_complete_frame(buffer, sample_buffer, reset_state)
    else
      reset_state
    end
  end

  defp maybe_force_process(state, _buffer, _sample_buffer), do: state

  # -------------------------------------------------------------------
  # Threshold computation
  # -------------------------------------------------------------------

  # Use adaptive threshold: max of fixed minimum and 3× noise floor.
  # This prevents false triggers in very quiet conditions while still
  # working when the noise floor is elevated (e.g., HF band noise).
  defp effective_threshold(state) do
    max(@squelch_threshold, state.noise_floor_rms * 3.0)
  end

  # -------------------------------------------------------------------
  # Energy measurement
  # -------------------------------------------------------------------

  defp compute_rms([]), do: 0.0

  defp compute_rms(samples) do
    n = length(samples)
    sum_sq = Enum.reduce(samples, 0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_sq / n)
  end

  # -------------------------------------------------------------------
  # AGC
  # -------------------------------------------------------------------

  # Simple AGC: normalize samples to prevent clipping
  # Target peak amplitude of ~20000 (leaves headroom below 32767)
  @agc_target_peak 20000

  defp apply_agc(samples) when length(samples) < 10, do: samples

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
  ## Frame Processing (operates on a complete symbol buffer)
  ## ------------------------------------------------------------------

  defp process_complete_frame(symbols, raw_samples, state) do
    first_32 = Enum.take(symbols, 32)
    Logger.info("[ALE RX #{short(state.rig_id)}] Attempting frame decode: #{length(symbols)} symbols, #{length(raw_samples)} samples, first 32: #{inspect(first_32)}")
    {_remaining, decoded_results, _state} = find_frames(symbols, raw_samples, state)

    if decoded_results == [] do
      Logger.info("[ALE RX #{short(state.rig_id)}] No PDUs decoded from #{length(symbols)} symbols")
    end

    # Get current frequency from rig control for LQA recording
    freq_hz = case safe_get_frequency(state.rig_id) do
      {:ok, freq} -> freq
      _ -> nil
    end

    Enum.each(decoded_results, fn {pdu, metrics} ->
      Logger.info("ALE RX [#{state.rig_id}] decoded PDU: #{inspect(pdu)}")

      :telemetry.execute(
        [:minutemodem, :ale, :pdu],
        %{symbol_count: length(symbols)},
        %{rig_id: state.rig_id, pdu_type: pdu_type_name(pdu), waveform: detect_waveform_from_symbols(symbols)}
      )

      # Record LQA observation if we know the source address and frequency
      source_addr = LQA.source_addr(pdu)
      if source_addr && freq_hz do
        lqa_metrics = Map.merge(metrics, %{waveform: detect_waveform_from_symbols(symbols)})
        try do
          LQA.record_observation(state.rig_id, source_addr, freq_hz, lqa_metrics,
            frame_type: LQA.frame_type(pdu))
        rescue
          e -> Logger.warning("[ALE RX] LQA record failed: #{inspect(e)}")
        end
      end

      Link.rx_pdu(state.rig_id, pdu)
    end)

    state
  end

  defp safe_get_frequency(rig_id) do
    Control.get_frequency(rig_id)
  catch
    :exit, _ -> {:error, :not_available}
  end

  defp find_frames(symbols, raw_samples, state) do
    case find_capture_probe(symbols) do
      {:found, offset, _rest, phase_info} ->
        Logger.info("[ALE RX] Found capture probe at offset #{offset}, corr=#{phase_info.correlation}")

        frame_start = offset + @full_probe_length
        frame_symbols = Enum.drop(symbols, frame_start)

        phase_scores = Enum.map(0..7, fn phase ->
          corrected = Enum.map(frame_symbols, fn s -> rem(s - phase + 8, 8) end)
          first_block = Enum.take(corrected, 32)

          case Walsh.descramble_preamble(first_block) do
            {:error, _} ->
              {phase, 0, -1000}

            descrambled ->
              zeros = Enum.count(descrambled, &(&1 == 0))

              waveform_score = case Waveform.detect_waveform(corrected) do
                {:ok, _, %{correlation_score: score}} -> score
                _ -> -1000
              end

              {phase, zeros, waveform_score}
          end
        end)

        {best_phase, best_zeros, best_wf} = Enum.max_by(phase_scores, fn {_p, z, w} -> {z, w} end)

        Logger.info("[ALE RX] Best phase: #{best_phase} (#{best_phase * 45}°), zeros=#{best_zeros}, wf_score=#{best_wf}")

        :telemetry.execute(
          [:minutemodem, :ale, :probe],
          %{
            correlation: phase_info.correlation,
            offset: offset,
            phase_deg: best_phase * 45,
            preamble_zeros: best_zeros,
            waveform_score: best_wf
          },
          %{rig_id: state.rig_id, result: :found, peak_corr: abs(phase_info.correlation), peak_offset: offset}
        )

        corrected = Enum.map(frame_symbols, fn s ->
          rem(s - best_phase + 8, 8)
        end)

        sample_offset = frame_start * @samples_per_symbol
        frame_samples = Enum.drop(raw_samples, sample_offset)

        case decode_frame(corrected, frame_samples, state.rig_id) do
          {:ok, pdu, remaining, decode_metrics} ->
            # Merge probe-level metrics with decode-level metrics for LQA
            combined_metrics = Map.merge(decode_metrics, %{
              probe_corr: abs(phase_info.correlation),
              preamble_zeros: best_zeros
            })

            remaining_samples = Enum.drop(frame_samples, length(corrected) * @samples_per_symbol)
            {final_remaining, more_results, final_state} = find_frames(remaining, remaining_samples, state)
            {final_remaining, [{pdu, combined_metrics} | more_results], final_state}

          :incomplete ->
            Logger.info("[ALE RX] Frame incomplete: only #{length(corrected)} symbols after probe")
            {[], [], state}

          :error ->
            Logger.info("[ALE RX] Frame decode failed after phase correction")
            {[], [], state}
        end

      :not_found ->
        Logger.info("[ALE RX] No capture probe found in #{length(symbols)} symbols")
        :telemetry.execute(
          [:minutemodem, :ale, :probe],
          %{correlation: 0, offset: 0, phase_deg: 0, preamble_zeros: 0, waveform_score: 0},
          %{rig_id: state.rig_id, result: :not_found, peak_corr: 0, peak_offset: 0}
        )
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
    {best_result, peak_corr, peak_offset} = find_probe_scan(symbols, 0, {:not_found, 0, 0})

    case best_result do
      :not_found ->
        Logger.info("[ALE RX] Probe search failed: peak |corr|=#{peak_corr} at offset #{peak_offset} (threshold=20)")
        :not_found
      found ->
        found
    end
  end

  defp find_probe_scan(symbols, offset, {best, peak_corr, peak_offset})
       when length(symbols) - offset < @full_probe_length do
    {best, peak_corr, peak_offset}
  end

  defp find_probe_scan(symbols, offset, {best, peak_corr, peak_offset}) do
    window = Enum.slice(symbols, offset, @probe_length)
    {best_offset, best_corr} = find_best_phase_offset(window, @capture_probe_prefix)

    {new_best, new_peak, new_peak_off} = if abs(best_corr) > 20 do
      phase_correction = if best_corr > 0, do: best_offset, else: rem(best_offset + 4, 8)
      phase_info = %{offset: phase_correction, correlation: best_corr}
      {{:found, offset, nil, phase_info}, abs(best_corr), offset}
    else
      new_peak = if abs(best_corr) > peak_corr, do: abs(best_corr), else: peak_corr
      new_off = if abs(best_corr) > peak_corr, do: offset, else: peak_offset
      {best, new_peak, new_off}
    end

    case new_best do
      {:found, _, _, _} -> {new_best, new_peak, new_peak_off}
      _ -> find_probe_scan(symbols, offset + 1, {new_best, new_peak, new_peak_off})
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

  defp decode_frame(symbols, _samples, _rig_id) when length(symbols) < @deep_preamble_symbols do
    :incomplete
  end

  defp decode_frame(symbols, samples, rig_id) do
    case Waveform.detect_waveform(symbols) do
      {:ok, :deep, preamble_info} ->
        Logger.info("[ALE RX] Detected Deep WALE, more_pdus=#{preamble_info.more_pdus}")
        decode_deep_wale_frame(symbols, samples, rig_id)

      {:ok, :fast, preamble_info} ->
        Logger.info("[ALE RX] Detected Fast WALE, more_pdus=#{preamble_info.more_pdus}")
        decode_fast_wale_frame(symbols, rig_id)

      {:error, reason} ->
        Logger.info("[ALE RX] Waveform detection failed: #{inspect(reason)}")
        :error
    end
  end

  defp decode_deep_wale_frame(symbols, raw_samples, rig_id) do
    alias MinuteModemCore.ALE.Waveform.SoftWalsh

    data_start = @deep_preamble_symbols
    data_symbols = Enum.slice(symbols, data_start, @deep_data_symbols)

    min_data_symbols = @deep_data_symbols - 64

    if length(data_symbols) < min_data_symbols do
      Logger.info("[ALE RX] Deep WALE incomplete: #{length(data_symbols)} < #{min_data_symbols}")
      :incomplete
    else
      data_symbols = if length(data_symbols) < @deep_data_symbols do
        data_symbols ++ List.duplicate(0, @deep_data_symbols - length(data_symbols))
      else
        data_symbols
      end

      sample_start = data_start * @samples_per_symbol
      data_samples = Enum.slice(raw_samples, sample_start, @deep_data_symbols * @samples_per_symbol)

      result = if length(data_samples) >= @deep_data_symbols * @samples_per_symbol do
        demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
        PhyModem.unified_demod_set_block_size(demod, 999_999)
        iq_pairs = PhyModem.unified_demod_iq(demod, data_samples)

        data_iq = Enum.take(iq_pairs, @deep_data_symbols)

        if length(data_iq) >= min_data_symbols do
          Logger.info("[ALE RX] Using soft I/Q decode path (#{length(data_iq)} I/Q pairs)")
          decode_deep_wale_soft_iq(data_iq, rig_id)
        else
          Logger.info("[ALE RX] Insufficient I/Q pairs (#{length(data_iq)}), falling back to hard decode")
          decode_deep_wale_hard(data_symbols, rig_id)
        end
      else
        Logger.info("[ALE RX] Insufficient raw samples for I/Q, using hard decode")
        decode_deep_wale_hard(data_symbols, rig_id)
      end

      case result do
        {:ok, pdu, decode_metrics} ->
          remaining = Enum.drop(symbols, data_start + @deep_data_symbols)
          {:ok, pdu, remaining, decode_metrics}
        :error -> :error
      end
    end
  end

  defp decode_deep_wale_soft_iq(data_iq, rig_id) do
    alias MinuteModemCore.ALE.Waveform.SoftWalsh

    case SoftWalsh.decode_iq_with_dfe(data_iq) do
      {:soft, soft_dibits, _scrambler, _hard_dibits} ->
        # Compute LLR statistics before decoding
        llr_magnitudes = soft_dibits |> Enum.flat_map(fn {l1, l2} -> [abs(l1), abs(l2)] end)
        avg_llr = Enum.sum(llr_magnitudes) / max(length(llr_magnitudes), 1)
        min_llr = Enum.min(llr_magnitudes, fn -> 0.0 end)

        deinterleaved = Encoding.deinterleave_soft(soft_dibits, 12, 16)
        case viterbi_decode_soft(deinterleaved) do
          {:ok, decoded_bits, terminal} ->
            decode_metrics = Map.merge(terminal, %{
              symbol_count: length(data_iq),
              avg_llr: avg_llr,
              min_llr: min_llr,
              decode_path: :soft_iq
            })

            :telemetry.execute(
              [:minutemodem, :ale, :decode],
              Map.merge(terminal, %{
                symbol_count: length(data_iq),
                avg_llr: avg_llr,
                min_llr: min_llr
              }),
              %{rig_id: rig_id, waveform: :deep, decode_path: :soft_iq,
                result: :ok, error_reason: nil}
            )

            case bits_to_pdu(decoded_bits) do
              {:ok, pdu} -> {:ok, pdu, decode_metrics}
              {:error, reason} ->
                Logger.info("[ALE RX] Soft decode PDU parse failed: #{inspect(reason)}")
                :error
            end
          {:error, reason} ->
            :telemetry.execute(
              [:minutemodem, :ale, :decode],
              %{symbol_count: length(data_iq), path_metric: 0.0,
                path_metric_delta: 0.0, avg_llr: avg_llr, min_llr: min_llr},
              %{rig_id: rig_id, waveform: :deep, decode_path: :soft_iq,
                result: :error, error_reason: reason}
            )
            Logger.info("[ALE RX] Soft Viterbi decode failed: #{inspect(reason)}")
            :error
        end

      {hard_dibits, _scrambler} ->
        deinterleaved = Encoding.deinterleave(hard_dibits, 12, 16)
        case viterbi_decode(deinterleaved) do
          {:ok, decoded_bits, terminal} ->
            decode_metrics = Map.merge(terminal, %{
              symbol_count: length(data_iq),
              decode_path: :hard
            })

            :telemetry.execute(
              [:minutemodem, :ale, :decode],
              Map.merge(terminal, %{symbol_count: length(data_iq)}),
              %{rig_id: rig_id, waveform: :deep, decode_path: :hard,
                result: :ok, error_reason: nil}
            )

            case bits_to_pdu(decoded_bits) do
              {:ok, pdu} -> {:ok, pdu, decode_metrics}
              {:error, reason} ->
                Logger.info("[ALE RX] Hard fallback PDU parse failed: #{inspect(reason)}")
                :error
            end
          {:error, _} -> :error
        end
    end
  end

  defp decode_deep_wale_hard(data_symbols, rig_id) do
    {dibits, _scrambler} = DeepWale.decode_data(data_symbols)
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)
    case viterbi_decode(deinterleaved) do
      {:ok, decoded_bits, terminal} ->
        decode_metrics = Map.merge(terminal, %{
          symbol_count: length(data_symbols),
          decode_path: :hard
        })

        :telemetry.execute(
          [:minutemodem, :ale, :decode],
          Map.merge(terminal, %{symbol_count: length(data_symbols)}),
          %{rig_id: rig_id, waveform: :deep, decode_path: :hard,
            result: :ok, error_reason: nil}
        )

        case bits_to_pdu(decoded_bits) do
          {:ok, pdu} -> {:ok, pdu, decode_metrics}
          {:error, reason} ->
            Logger.info("[ALE RX] Hard decode PDU parse failed: #{inspect(reason)}")
            :error
        end
      {:error, _} -> :error
    end
  end

  # Decode Fast WALE frame
  # Structure: [Preamble: 288] [K: 32] [U: 96] [K: 32] [U: 96]...
  defp decode_fast_wale_frame(symbols, rig_id) do
    # Skip preamble and initial probe
    data_start = @fast_preamble_symbols + @fast_initial_probe
    data_symbols = Enum.drop(symbols, data_start)

    # === Phase coherence for Fast WALE ===
    first_preamble_block = Enum.take(symbols, 32)
    last_preamble_block = Enum.slice(symbols, 256, 32)
    first_descrambled = Walsh.descramble_preamble(first_preamble_block)
    last_descrambled = Walsh.descramble_preamble(last_preamble_block)
    first_zeros = Enum.count(first_descrambled, &(&1 == 0))
    last_zeros = Enum.count(last_descrambled, &(&1 == 0))
    Logger.info("[ALE RX] Fast phase coherence: preamble_start=#{first_zeros}/32, preamble_end=#{last_zeros}/32")

    # Decode through Fast WALE path
    dibits = FastWale.decode_data(data_symbols)

    # Deinterleave
    deinterleaved = Encoding.deinterleave(dibits, 12, 16)

    # Viterbi decode
    case viterbi_decode(deinterleaved) do
      {:ok, decoded_bits, terminal} ->
        decoded_bytes = bits_to_bytes(Enum.drop(decoded_bits, -6))
        Logger.info("[ALE RX] Fast Viterbi: #{length(decoded_bytes)} bytes, first 12: #{inspect(Enum.take(decoded_bytes, 12))}")

        decode_metrics = Map.merge(terminal, %{
          symbol_count: length(symbols),
          decode_path: :fast
        })

        :telemetry.execute(
          [:minutemodem, :ale, :decode],
          Map.merge(terminal, %{symbol_count: length(symbols)}),
          %{rig_id: rig_id, waveform: :fast, decode_path: :fast,
            result: :ok, error_reason: nil}
        )

        case bits_to_pdu(decoded_bits) do
          {:ok, pdu} ->
            # Estimate consumed symbols (data + probes)
            num_blocks = div(length(dibits) * 2 + 127, 128)
            consumed = data_start + num_blocks * 128
            remaining = Enum.drop(symbols, consumed)
            {:ok, pdu, remaining, decode_metrics}
          {:error, reason} ->
            type_names = %{0x68 => "LsuReq", 0x69 => "LsuConf", 0x6A => "LsuTerm"}
            first_byte = List.first(decoded_bytes) || 0
            type_name = Map.get(type_names, first_byte, "Unknown(0x#{Integer.to_string(first_byte, 16)})")
            Logger.info("[ALE RX] Fast PDU failed: #{inspect(reason)}, type=#{type_name}")
            :error
        end

      {:error, reason} ->
        :telemetry.execute(
          [:minutemodem, :ale, :decode],
          %{symbol_count: length(symbols), path_metric: 0, path_metric_delta: 0},
          %{rig_id: rig_id, waveform: :fast, decode_path: :fast,
            result: :error, error_reason: reason}
        )
        Logger.info("[ALE RX] Viterbi decode failed: #{inspect(reason)}")
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
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    terminal = extract_terminal_metrics(final_metrics)
    {:ok, decoded, terminal}
  end

  defp viterbi_decode_soft(soft_dibits) do
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0.0, else: 100_000.0)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    {final_metrics, final_paths} =
      Enum.reduce(soft_dibits, {initial_metrics, initial_paths}, fn soft_dibit, {metrics, paths} ->
        viterbi_step_soft(metrics, paths, soft_dibit)
      end)

    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()
    terminal = extract_terminal_metrics(final_metrics)
    {:ok, decoded, terminal}
  end

  # Extract path_metric and delta from final Viterbi state.
  # path_metric_delta is the gap between state-0 and the next-best state —
  # a larger delta means higher decode confidence.
  defp extract_terminal_metrics(final_metrics) do
    state0_metric = Map.get(final_metrics, 0, 0)
    next_best = final_metrics
      |> Enum.reject(fn {s, _} -> s == 0 end)
      |> Enum.map(fn {_, m} -> m end)
      |> Enum.min(fn -> state0_metric end)

    %{
      path_metric: state0_metric,
      path_metric_delta: next_best - state0_metric
    }
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

  defp viterbi_step_soft(metrics, paths, {llr1, llr2}) do
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        input_bit = band(next_state, 1)
        prev_state = bsr(next_state, 1)
        prev_state_alt = bor(prev_state, 0x20)

        {exp1, exp2} = expected_output(prev_state, input_bit)
        {exp1_alt, exp2_alt} = expected_output(prev_state_alt, input_bit)

        bm = soft_bm(exp1, llr1) + soft_bm(exp2, llr2)
        bm_alt = soft_bm(exp1_alt, llr1) + soft_bm(exp2_alt, llr2)

        pm = Map.get(metrics, prev_state, 100_000.0) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 100_000.0) + bm_alt

        if pm <= pm_alt do
          {next_state, pm, [input_bit | Map.get(paths, prev_state, [])]}
        else
          {next_state, pm_alt, [input_bit | Map.get(paths, prev_state_alt, [])]}
        end
      end

    {Map.new(new_state_data, fn {s, m, _} -> {s, m} end),
     Map.new(new_state_data, fn {s, _, p} -> {s, p} end)}
  end

  defp soft_bm(expected_bit, llr) do
    if expected_bit == 1, do: -llr, else: llr
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

  # Estimate the phase offset at a given preamble position.
  # The first fixed dibit of every preamble is 0, which maps to Walsh normal(0) = all zeros.
  # After preamble descrambling, all-zeros BPSK means every symbol should be 0.
  # The modal value of the descrambled block tells us the phase offset.
  defp estimate_preamble_phase(symbols, offset) do
    block = Enum.slice(symbols, offset, 32)
    descrambled = Walsh.descramble_preamble(block)

    # Count occurrences of each value 0-7
    counts = Enum.frequencies(descrambled)

    # The most common value is the phase offset (should be 0 or 4 for BPSK)
    {phase, _count} = Enum.max_by(counts, fn {_val, count} -> count end)
    phase
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp short(rig_id) when is_binary(rig_id), do: String.slice(rig_id, 0, 8)
  defp short(rig_id), do: inspect(rig_id)

  defp pdu_type_name(%{__struct__: struct}) do
    struct
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end
  defp pdu_type_name(%{type: type}), do: type
  defp pdu_type_name(_), do: :unknown

  defp detect_waveform_from_symbols(symbols) when length(symbols) > 700 do
    # Deep WALE has 576-symbol preamble, Fast has 288.
    # If we have enough symbols, check which waveform was detected.
    case Waveform.detect_waveform(Enum.drop(symbols, 96)) do
      {:ok, wf, _} -> wf
      _ -> :unknown
    end
  end
  defp detect_waveform_from_symbols(_), do: :unknown
end
