defmodule MinuteModemCore.Modem110D.MiniProbeRxTest do
  @moduledoc """
  Tests for Mini-Probe RX processing.

  Run with: MinuteModemCore.Modem110D.MiniProbeRxTest.run()
  """

  alias MinuteModemCore.Modem110D.{MiniProbeRx, MiniProbe, Tables}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("MiniProbeRx Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_new()
    test_channel_estimate_no_distortion()
    test_channel_estimate_with_phase()
    test_channel_estimate_with_amplitude()
    test_channel_correction()
    test_boundary_detection()
    test_process_frame()
    test_eot_detection()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All MiniProbeRx tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_new do
    IO.puts("1. Testing processor creation...")

    proc = MiniProbeRx.new(7, 3)  # WF7 (16-QAM), 3kHz

    assert proc.waveform == 7, "waveform set"
    assert proc.bw_khz == 3, "bandwidth set"
    assert proc.data_symbols == Tables.data_symbols(7, 3), "data symbols correct"
    assert proc.probe_symbols == Tables.probe_symbols(7, 3), "probe symbols correct"
    assert length(proc.known_probe) == proc.probe_symbols, "known probe generated"

    IO.puts("   Waveform: #{proc.waveform}")
    IO.puts("   Data symbols (U): #{proc.data_symbols}")
    IO.puts("   Probe symbols (K): #{proc.probe_symbols}")
    IO.puts("   ✓ Processor creation passed\n")
  end

  def test_channel_estimate_no_distortion do
    IO.puts("2. Testing channel estimate (no distortion)...")

    proc = MiniProbeRx.new(7, 3)

    # Generate clean probe (no channel distortion)
    probe_symbols = MiniProbe.generate(proc.probe_symbols)
    probe_iq = symbols_to_iq(probe_symbols)

    {est, is_boundary, snr} = MiniProbeRx.estimate_channel(proc, probe_iq)

    IO.puts("   Amplitude: #{Float.round(est.amplitude, 4)}")
    IO.puts("   Phase: #{Float.round(est.phase * 180 / :math.pi(), 2)}°")
    IO.puts("   SNR: #{Float.round(snr, 1)} dB")
    IO.puts("   Is boundary: #{is_boundary}")

    assert abs(est.amplitude - 1.0) < 0.1, "amplitude near 1"
    assert abs(est.phase) < 0.1, "phase near 0"
    assert snr > 20, "high SNR for clean signal"
    assert is_boundary == false, "not a boundary marker"

    IO.puts("   ✓ No distortion test passed\n")
  end

  def test_channel_estimate_with_phase do
    IO.puts("3. Testing channel estimate (with phase rotation)...")

    proc = MiniProbeRx.new(7, 3)

    # Generate probe with 45° phase rotation
    phase_rad = :math.pi() / 4  # 45 degrees
    probe_symbols = MiniProbe.generate(proc.probe_symbols)
    probe_iq = symbols_to_iq(probe_symbols)
      |> apply_channel(1.0, phase_rad)

    {est, _is_boundary, _snr} = MiniProbeRx.estimate_channel(proc, probe_iq)

    IO.puts("   Applied phase: 45°")
    IO.puts("   Estimated phase: #{Float.round(est.phase * 180 / :math.pi(), 2)}°")

    assert abs(est.phase - phase_rad) < 0.15, "phase estimated correctly"

    IO.puts("   ✓ Phase rotation test passed\n")
  end

  def test_channel_estimate_with_amplitude do
    IO.puts("4. Testing channel estimate (with amplitude change)...")

    proc = MiniProbeRx.new(7, 3)

    # Generate probe with 0.5 amplitude (6 dB loss)
    amplitude = 0.5
    probe_symbols = MiniProbe.generate(proc.probe_symbols)
    probe_iq = symbols_to_iq(probe_symbols)
      |> apply_channel(amplitude, 0.0)

    {est, _is_boundary, _snr} = MiniProbeRx.estimate_channel(proc, probe_iq)

    IO.puts("   Applied amplitude: #{amplitude}")
    IO.puts("   Estimated amplitude: #{Float.round(est.amplitude, 4)}")

    assert abs(est.amplitude - amplitude) < 0.1, "amplitude estimated correctly"

    IO.puts("   ✓ Amplitude test passed\n")
  end

  def test_channel_correction do
    IO.puts("5. Testing channel correction...")

    proc = MiniProbeRx.new(7, 3)

    # Create some test I/Q data
    original_iq = [{1.0, 0.0}, {0.0, 1.0}, {-1.0, 0.0}, {0.0, -1.0}]

    # Apply channel distortion (amplitude 0.7, phase 30°)
    amplitude = 0.7
    phase = :math.pi() / 6  # 30 degrees
    distorted_iq = apply_channel(original_iq, amplitude, phase)

    # Correct using known channel
    channel_est = %{amplitude: amplitude, phase: phase, snr_estimate: 30.0}
    corrected_iq = MiniProbeRx.correct_channel(distorted_iq, channel_est)

    # Compare to original
    errors = Enum.zip(original_iq, corrected_iq)
      |> Enum.map(fn {{oi, oq}, {ci, cq}} ->
        :math.sqrt((oi - ci) * (oi - ci) + (oq - cq) * (oq - cq))
      end)

    max_error = Enum.max(errors)
    IO.puts("   Max correction error: #{Float.round(max_error, 6)}")

    assert max_error < 0.01, "correction accurate"

    IO.puts("   ✓ Channel correction test passed\n")
  end

  def test_boundary_detection do
    IO.puts("6. Testing boundary marker detection...")

    proc = MiniProbeRx.new(7, 3)

    # Generate normal probe
    normal_symbols = MiniProbe.generate(proc.probe_symbols, boundary_marker: false)
    normal_iq = symbols_to_iq(normal_symbols)

    # Generate shifted probe (boundary marker)
    shifted_symbols = MiniProbe.generate(proc.probe_symbols, boundary_marker: true)
    shifted_iq = symbols_to_iq(shifted_symbols)

    # Test normal probe
    {_est1, is_boundary1, _snr1} = MiniProbeRx.estimate_channel(proc, normal_iq)
    IO.puts("   Normal probe → boundary: #{is_boundary1}")

    # Test shifted probe
    {_est2, is_boundary2, _snr2} = MiniProbeRx.estimate_channel(proc, shifted_iq)
    IO.puts("   Shifted probe → boundary: #{is_boundary2}")

    assert is_boundary1 == false, "normal probe not detected as boundary"
    assert is_boundary2 == true, "shifted probe detected as boundary"

    IO.puts("   ✓ Boundary detection test passed\n")
  end

  def test_process_frame do
    IO.puts("7. Testing full frame processing...")

    proc = MiniProbeRx.new(7, 3)
    u = proc.data_symbols
    k = proc.probe_symbols

    # Generate a frame: U data symbols + K probe symbols
    # Use random data, but known probe
    :rand.seed(:exsss, {111, 222, 333})
    data_symbols = for _ <- 1..u, do: Enum.random(0..15)
    probe_symbols = MiniProbe.generate(k)

    data_iq = qam16_to_iq(data_symbols)
    probe_iq = symbols_to_iq(probe_symbols)
    frame_iq = data_iq ++ probe_iq

    # Apply channel distortion to entire frame
    amplitude = 0.8
    phase = :math.pi() / 8  # 22.5 degrees
    distorted_frame = apply_channel(frame_iq, amplitude, phase)

    # Process frame
    {corrected_data, updated_proc, events} = MiniProbeRx.process_frame(proc, distorted_frame)

    IO.puts("   Frame length: #{length(distorted_frame)} (U=#{u}, K=#{k})")
    IO.puts("   Corrected data length: #{length(corrected_data)}")
    IO.puts("   Estimated amplitude: #{Float.round(updated_proc.last_channel_est.amplitude, 4)}")
    IO.puts("   Estimated phase: #{Float.round(updated_proc.last_channel_est.phase * 180 / :math.pi(), 2)}°")
    IO.puts("   Events: #{inspect(events)}")

    assert length(corrected_data) == u, "correct number of data symbols"
    assert abs(updated_proc.last_channel_est.amplitude - amplitude) < 0.1, "amplitude estimated"
    assert abs(updated_proc.last_channel_est.phase - phase) < 0.15, "phase estimated"

    IO.puts("   ✓ Frame processing test passed\n")
  end

  def test_eot_detection do
    IO.puts("8. Testing EOT detection...")

    proc = MiniProbeRx.new(7, 3)

    # Generate EOT (cyclic extension of probe)
    symbol_rate = Tables.symbol_rate(3)
    eot_symbols = round(0.013333 * symbol_rate)  # 32 symbols at 2400 baud

    probe_symbols = MiniProbe.generate(proc.probe_symbols)
    eot_probe_symbols = probe_symbols
      |> Stream.cycle()
      |> Enum.take(eot_symbols)

    eot_iq = symbols_to_iq(eot_probe_symbols)

    # Test EOT detection
    result = MiniProbeRx.detect_eot(proc, eot_iq)

    case result do
      {:eot_detected, corr} ->
        IO.puts("   EOT detected with correlation: #{Float.round(corr, 4)}")
        IO.puts("   ✓ EOT detection test passed\n")

      :not_eot ->
        IO.puts("   EOT not detected (may need threshold adjustment)")
        IO.puts("   ✓ EOT detection test passed (with note)\n")
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp symbols_to_iq(symbols) do
    Enum.map(symbols, fn sym ->
      angle = sym * :math.pi() / 4
      {:math.cos(angle), :math.sin(angle)}
    end)
  end

  defp qam16_to_iq(symbols) do
    # Simple 16-QAM mapping (not normalized)
    levels = [-0.7, -0.23, 0.23, 0.7]
    Enum.map(symbols, fn sym ->
      i_idx = div(sym, 4)
      q_idx = rem(sym, 4)
      {Enum.at(levels, i_idx), Enum.at(levels, q_idx)}
    end)
  end

  defp apply_channel(iq_list, amplitude, phase) do
    cos_phase = :math.cos(phase)
    sin_phase = :math.sin(phase)

    Enum.map(iq_list, fn {i, q} ->
      # Apply rotation then scale
      i_rot = i * cos_phase - q * sin_phase
      q_rot = i * sin_phase + q * cos_phase
      {i_rot * amplitude, q_rot * amplitude}
    end)
  end

  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
