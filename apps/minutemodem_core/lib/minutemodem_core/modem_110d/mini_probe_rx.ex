defmodule MinuteModemCore.Modem110D.MiniProbeRx do
  @moduledoc """
  MIL-STD-188-110D Mini-Probe Receiver Processing.

  Mini-probes are known symbol sequences inserted after each data block.
  On RX, they are used for:
  - Channel estimation (amplitude and phase)
  - Tracking channel variations during data reception
  - Detecting interleaver boundaries (via shifted probe detection)
  - EOT detection (cyclic extension of last probe)

  ## Channel Model

  The received signal is modeled as:

      r(t) = h(t) * s(t) + n(t)

  Where:
  - h(t) = complex channel gain (amplitude + phase)
  - s(t) = transmitted signal
  - n(t) = noise

  For narrowband HF (single tone), h is approximately constant over a mini-probe,
  so we estimate it as:

      h_est = sum(r_i * conj(s_i)) / sum(|s_i|^2)

  ## Usage

      # Create processor for a waveform
      proc = MiniProbeRx.new(waveform, bw_khz)

      # Process a data frame (data + probe)
      {corrected_data, channel_est, events} = MiniProbeRx.process_frame(proc, frame_iq)

      # Or process probe separately
      {channel_est, is_boundary, snr} = MiniProbeRx.estimate_channel(proc, probe_iq)
  """

  alias MinuteModemCore.Modem110D.{Tables, MiniProbe}

  require Logger

  defstruct [
    :waveform,
    :bw_khz,
    :data_symbols,      # U - number of data symbols per frame
    :probe_symbols,     # K - number of probe symbols
    :known_probe,       # Known probe I/Q sequence (normal)
    :known_probe_shifted,  # Known probe I/Q sequence (boundary shifted)
    :last_channel_est,  # Last channel estimate {amplitude, phase}
    :channel_history,   # List of recent estimates for smoothing
    :boundary_threshold # Correlation threshold for boundary detection
  ]

  @type channel_estimate :: %{
    amplitude: float(),
    phase: float(),
    snr_estimate: float()
  }

  @type t :: %__MODULE__{
    waveform: non_neg_integer(),
    bw_khz: pos_integer(),
    data_symbols: pos_integer(),
    probe_symbols: pos_integer(),
    known_probe: [{float(), float()}],
    known_probe_shifted: [{float(), float()}],
    last_channel_est: channel_estimate() | nil,
    channel_history: [channel_estimate()],
    boundary_threshold: float()
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Create a new mini-probe processor.

  ## Arguments
  - `waveform` - Waveform number (1-12)
  - `bw_khz` - Bandwidth in kHz

  ## Options
  - `:boundary_threshold` - Correlation threshold for boundary detection (default: 0.7)
  - `:history_length` - Number of estimates to keep for smoothing (default: 4)
  """
  def new(waveform, bw_khz, opts \\ []) do
    boundary_threshold = Keyword.get(opts, :boundary_threshold, 0.7)

    u = Tables.data_symbols(waveform, bw_khz)
    k = Tables.probe_symbols(waveform, bw_khz)

    # Generate known probe sequences
    probe_symbols_normal = MiniProbe.generate(k, boundary_marker: false)
    probe_symbols_shifted = MiniProbe.generate(k, boundary_marker: true)

    Logger.debug("[MiniProbeRx.new] waveform=#{waveform}, k=#{k}, probe_symbols (first 8): #{inspect(Enum.take(probe_symbols_normal, 8))}")

    # Convert to I/Q
    known_normal = symbols_to_iq(probe_symbols_normal)
    known_shifted = symbols_to_iq(probe_symbols_shifted)

    %__MODULE__{
      waveform: waveform,
      bw_khz: bw_khz,
      data_symbols: u,
      probe_symbols: k,
      known_probe: known_normal,
      known_probe_shifted: known_shifted,
      last_channel_est: nil,
      channel_history: [],
      boundary_threshold: boundary_threshold
    }
  end

  @doc """
  Process a complete data frame (U data symbols + K probe symbols).

  ## Arguments
  - `proc` - MiniProbeRx processor
  - `frame_iq` - List of {I, Q} tuples for the entire frame

  ## Returns
  `{corrected_data_iq, updated_proc, events}` where:
  - `corrected_data_iq` - Channel-corrected data I/Q samples
  - `updated_proc` - Updated processor state
  - `events` - List of events (e.g., `{:boundary_detected}`)
  """
  def process_frame(%__MODULE__{} = proc, frame_iq) when is_list(frame_iq) do
    u = proc.data_symbols
    k = proc.probe_symbols

    expected_len = u + k
    actual_len = length(frame_iq)

    if actual_len < expected_len do
      # Not enough data, return uncorrected
      {frame_iq, proc, [{:error, {:frame_too_short, actual_len, expected_len}}]}
    else
      # Split into data and probe
      data_iq = Enum.take(frame_iq, u)
      probe_iq = Enum.slice(frame_iq, u, k)

      # Estimate channel from probe
      {channel_est, is_boundary, _corr_normal, _corr_shifted} =
        estimate_channel_internal(proc, probe_iq)

      # Correct data using channel estimate
      corrected_data = correct_channel(data_iq, channel_est)

      # Update processor state
      proc = update_channel_history(proc, channel_est)

      # Build events
      events = []
      events = if is_boundary, do: [{:boundary_detected} | events], else: events

      {corrected_data, proc, events}
    end
  end

  @doc """
  Estimate channel from probe symbols only.

  ## Arguments
  - `proc` - MiniProbeRx processor
  - `probe_iq` - List of {I, Q} tuples for probe symbols

  ## Returns
  `{channel_estimate, is_boundary, snr_db}`
  """
  def estimate_channel(%__MODULE__{} = proc, probe_iq) do
    {channel_est, is_boundary, _, _} = estimate_channel_internal(proc, probe_iq)
    {channel_est, is_boundary, channel_est.snr_estimate}
  end

  @doc """
  Apply channel correction to I/Q samples.

  ## Arguments
  - `iq_samples` - List of {I, Q} tuples
  - `channel_est` - Channel estimate map

  ## Returns
  List of corrected {I, Q} tuples
  """
  def correct_channel(iq_samples, %{amplitude: amp, phase: phase}) when amp > 0 do
    # Correction: divide by amplitude, rotate by -phase
    cos_neg_phase = :math.cos(-phase)
    sin_neg_phase = :math.sin(-phase)
    inv_amp = 1.0 / amp

    Enum.map(iq_samples, fn {i, q} ->
      # First remove amplitude
      i_scaled = i * inv_amp
      q_scaled = q * inv_amp

      # Then remove phase rotation
      i_corr = i_scaled * cos_neg_phase - q_scaled * sin_neg_phase
      q_corr = i_scaled * sin_neg_phase + q_scaled * cos_neg_phase

      {i_corr, q_corr}
    end)
  end

  def correct_channel(iq_samples, _channel_est) do
    # No valid estimate, return uncorrected
    iq_samples
  end

  @doc """
  Get the last channel estimate.
  """
  def last_estimate(%__MODULE__{last_channel_est: est}), do: est

  @doc """
  Get smoothed channel estimate (average of history).
  """
  def smoothed_estimate(%__MODULE__{channel_history: []}) do
    nil
  end

  def smoothed_estimate(%__MODULE__{channel_history: history}) do
    n = length(history)

    avg_amp = Enum.sum(Enum.map(history, & &1.amplitude)) / n

    # Average phase (need to handle wraparound)
    {sum_cos, sum_sin} = Enum.reduce(history, {0.0, 0.0}, fn est, {sc, ss} ->
      {sc + :math.cos(est.phase), ss + :math.sin(est.phase)}
    end)
    avg_phase = :math.atan2(sum_sin / n, sum_cos / n)

    avg_snr = Enum.sum(Enum.map(history, & &1.snr_estimate)) / n

    %{amplitude: avg_amp, phase: avg_phase, snr_estimate: avg_snr}
  end

  # ===========================================================================
  # EOT Detection
  # ===========================================================================

  @doc """
  Check if received symbols match EOT pattern (cyclic extension of probe).

  EOT is a 32-symbol cyclic extension that appears AFTER the normal mini-probe.
  This function checks if the provided IQ samples (which should be the symbols
  AFTER the normal probe) match a cyclic extension of the known probe.

  ## Arguments
  - `proc` - MiniProbeRx processor
  - `extension_iq` - I/Q samples that appear AFTER the normal mini-probe

  ## Returns
  `{:eot_detected, correlation}` or `:not_eot`
  """
  def detect_eot(%__MODULE__{} = proc, extension_iq) do
    # EOT extension length: 13.333ms worth of symbols = 32 symbols at 2400 baud
    symbol_rate = Tables.symbol_rate(proc.bw_khz)
    eot_extension_symbols = round(0.013333 * symbol_rate)

    # Frame length = data symbols + probe symbols
    frame_len = proc.data_symbols + proc.probe_symbols

    # CRITICAL: Only check for EOT when buffer is too small for another complete frame!
    # The mini-probe pattern appears throughout the transmission (after every data block),
    # so we'd get false positives if we check when there's still data remaining.
    # EOT should only be detected at the true end of transmission.
    buffer_len = length(extension_iq)

    if buffer_len >= frame_len do
      # Still have enough for another frame - this is NOT EOT
      :not_eot
    else
      # Buffer is too small for another frame - this could be EOT
      # Allow partial EOT detection (at least 75% of expected length)
      min_eot_symbols = div(eot_extension_symbols * 3, 4)  # 24 symbols minimum

      if buffer_len < min_eot_symbols do
        :not_eot
      else
        # Use actual buffer length if smaller than expected EOT
        actual_eot_len = min(buffer_len, eot_extension_symbols)

        # Apply channel correction using last estimate
        corrected_iq = case proc.last_channel_est do
          %{amplitude: amp, phase: phase} when amp > 0 ->
            cos_phase = :math.cos(-phase)
            sin_phase = :math.sin(-phase)
            Enum.map(extension_iq, fn {i, q} ->
              ci = (i * cos_phase - q * sin_phase) / amp
              cq = (i * sin_phase + q * cos_phase) / amp
              {ci, cq}
            end)
          _ ->
            extension_iq
        end

        # The extension continues the cyclic pattern from where the probe ended
        probe_len = proc.probe_symbols
        expected_extension = proc.known_probe
          |> Stream.cycle()
          |> Stream.drop(probe_len)
          |> Enum.take(actual_eot_len)

        # Search beginning of buffer (EOT should be at start of remaining data)
        max_search = max(0, buffer_len - actual_eot_len)
        search_offsets = Enum.to_list(0..min(16, max_search))

        {best_corr, best_offset} =
          search_offsets
          |> Enum.map(fn offset ->
            eot_iq = corrected_iq |> Enum.drop(offset) |> Enum.take(actual_eot_len)
            corr = correlation(eot_iq, expected_extension)
            {corr, offset}
          end)
          |> Enum.max_by(fn {corr, _} -> corr end)

        # Log for debugging
        received_at_best = corrected_iq
          |> Enum.drop(best_offset)
          |> Enum.take(min(8, actual_eot_len))
          |> Enum.map(fn {i, q} -> iq_to_symbol({i, q}) end)
        expected_symbols = expected_extension
          |> Enum.take(8)
          |> Enum.map(fn {i, q} -> iq_to_symbol({i, q}) end)
        Logger.debug("[MiniProbeRx.detect_eot] buffer=#{buffer_len} (< frame_len=#{frame_len}), using #{actual_eot_len} symbols")
        Logger.debug("[MiniProbeRx.detect_eot] best_corr=#{Float.round(best_corr, 3)} at offset=#{best_offset}")
        Logger.debug("[MiniProbeRx.detect_eot] Received: #{inspect(received_at_best)}, Expected: #{inspect(expected_symbols)}")

        if best_corr > 0.85 do
          {:eot_detected, best_corr}
        else
          :not_eot
        end
      end
    end
  end

  defp iq_to_symbol({i, q}) do
    angle = :math.atan2(q, i)
    angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle
    round(angle / (:math.pi() / 4)) |> rem(8)
  end

  # ===========================================================================
  # Internal Functions
  # ===========================================================================

  defp estimate_channel_internal(proc, probe_iq) do
    # Correlate with both normal and shifted probes
    corr_normal = complex_correlation(probe_iq, proc.known_probe)
    corr_shifted = complex_correlation(probe_iq, proc.known_probe_shifted)

    # Magnitude of correlations
    mag_normal = complex_magnitude(corr_normal)
    mag_shifted = complex_magnitude(corr_shifted)

    # Determine if this is a boundary marker
    is_boundary = mag_shifted > mag_normal * 1.1  # 10% margin

    # Use the better correlation for channel estimate
    {best_corr, _best_mag} = if is_boundary do
      {corr_shifted, mag_shifted}
    else
      {corr_normal, mag_normal}
    end

    # Channel estimate from correlation
    # h_est = correlation / sum(|s|^2)
    # For unit-magnitude known symbols, sum(|s|^2) = N
    n = length(probe_iq)
    {corr_i, corr_q} = best_corr

    amplitude = complex_magnitude(best_corr) / n
    phase = :math.atan2(corr_q, corr_i)

    # SNR estimate: compare signal power to residual noise
    snr_db = estimate_snr(probe_iq, proc.known_probe, amplitude, phase)

    channel_est = %{
      amplitude: amplitude,
      phase: phase,
      snr_estimate: snr_db
    }

    {channel_est, is_boundary, mag_normal, mag_shifted}
  end

  # Complex correlation: sum(r * conj(s))
  defp complex_correlation(received_iq, known_iq) do
    Enum.zip(received_iq, known_iq)
    |> Enum.reduce({0.0, 0.0}, fn {{ri, rq}, {ki, kq}}, {acc_i, acc_q} ->
      # r * conj(k) = (ri + j*rq) * (ki - j*kq)
      #             = (ri*ki + rq*kq) + j*(rq*ki - ri*kq)
      {acc_i + ri * ki + rq * kq, acc_q + rq * ki - ri * kq}
    end)
  end

  # Normalized correlation magnitude (0 to 1)
  defp correlation(received_iq, known_iq) do
    {corr_i, corr_q} = complex_correlation(received_iq, known_iq)
    mag = :math.sqrt(corr_i * corr_i + corr_q * corr_q)

    # Normalize by energies
    energy_r = Enum.reduce(received_iq, 0.0, fn {i, q}, acc -> acc + i*i + q*q end)
    energy_k = Enum.reduce(known_iq, 0.0, fn {i, q}, acc -> acc + i*i + q*q end)

    if energy_r > 0 and energy_k > 0 do
      mag / :math.sqrt(energy_r * energy_k)
    else
      0.0
    end
  end

  defp complex_magnitude({i, q}), do: :math.sqrt(i * i + q * q)

  defp estimate_snr(received_iq, known_iq, amplitude, phase) do
    # Reconstruct expected signal
    cos_phase = :math.cos(phase)
    sin_phase = :math.sin(phase)

    # Calculate signal and noise power
    {signal_power, noise_power} =
      Enum.zip(received_iq, known_iq)
      |> Enum.reduce({0.0, 0.0}, fn {{ri, rq}, {ki, kq}}, {sig_acc, noise_acc} ->
        # Expected received = amplitude * e^(j*phase) * known
        # = amplitude * (cos(phase) + j*sin(phase)) * (ki + j*kq)
        exp_i = amplitude * (ki * cos_phase - kq * sin_phase)
        exp_q = amplitude * (ki * sin_phase + kq * cos_phase)

        # Noise = received - expected
        noise_i = ri - exp_i
        noise_q = rq - exp_q

        sig_power = exp_i * exp_i + exp_q * exp_q
        n_power = noise_i * noise_i + noise_q * noise_q

        {sig_acc + sig_power, noise_acc + n_power}
      end)

    if noise_power > 1.0e-10 do
      10 * :math.log10(signal_power / noise_power)
    else
      99.0  # Very high SNR
    end
  end

  defp update_channel_history(proc, channel_est) do
    max_history = 4
    history = [channel_est | proc.channel_history] |> Enum.take(max_history)
    %{proc | last_channel_est: channel_est, channel_history: history}
  end

  # Convert 8-PSK symbol indices to I/Q
  defp symbols_to_iq(symbols) do
    Enum.map(symbols, fn sym ->
      angle = sym * :math.pi() / 4
      {:math.cos(angle), :math.sin(angle)}
    end)
  end
end
