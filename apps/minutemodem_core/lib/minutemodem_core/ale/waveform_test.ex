defmodule MinuteModemCore.ALE.WaveformTest do
  @moduledoc """
  Test the WALE waveform encoding/decoding.

  Run with: MinuteModemCore.ALE.WaveformTest.run()
  """

  alias MinuteModemCore.ALE.Waveform
  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, Walsh, Scrambler}
  alias MinuteModemCore.ALE.PDU

  def run do
    IO.puts("\n=== WALE Waveform Tests ===\n")

    test_walsh_tables()
    test_scramblers()
    test_deep_wale_preamble()
    test_fast_wale_preamble()
    test_deep_wale_data()
    test_fast_wale_data()
    test_full_frame_assembly()

    IO.puts("\n=== All Tests Complete ===\n")
  end

  def test_walsh_tables do
    IO.puts("1. Testing Walsh tables...")

    # Test normal set produces 32 symbols
    for dibit <- 0..3 do
      chips = Walsh.walsh_normal(dibit)
      assert length(chips) == 32, "Normal set dibit #{dibit} should produce 32 chips"
      assert Enum.all?(chips, &(&1 in [0, 4])), "Normal set should only use 0 and 4"
    end

    # Test exceptional set produces 32 symbols
    for dibit <- 0..3 do
      chips = Walsh.walsh_exceptional(dibit)
      assert length(chips) == 32, "Exceptional set dibit #{dibit} should produce 32 chips"
      assert Enum.all?(chips, &(&1 in [0, 4])), "Exceptional set should only use 0 and 4"
    end

    # Test Walsh-16 produces 64 symbols
    for quadbit <- 0..15 do
      syms = Walsh.walsh_16(quadbit)
      assert length(syms) == 64, "Walsh-16 quadbit #{quadbit} should produce 64 symbols"
      assert Enum.all?(syms, &(&1 in [0, 4])), "Walsh-16 should only use 0 and 4"
    end

    # Test capture probe
    probe = Walsh.capture_probe()
    assert length(probe) == 96, "Capture probe should be 96 symbols"

    IO.puts("   ✓ Walsh tables OK")
  end

  def test_scramblers do
    IO.puts("2. Testing scramblers...")

    # Deep WALE scrambler
    deep_scr = Scrambler.Deep.new()
    {tribit, deep_scr2} = Scrambler.Deep.next(deep_scr)
    assert tribit in 0..7, "Deep scrambler should output 0-7"
    assert deep_scr2.state != deep_scr.state, "State should change"

    # Test scramble/descramble roundtrip
    test_symbols = [0, 4, 0, 0, 4, 4, 0, 4] |> List.duplicate(8) |> List.flatten()
    {scrambled, _scr_final} = Scrambler.Deep.scramble(Scrambler.Deep.new(), test_symbols)
    {descrambled, _} = Scrambler.Deep.descramble(Scrambler.Deep.new(), scrambled)
    assert descrambled == test_symbols, "Deep scramble/descramble should roundtrip"

    # Fast WALE scrambler
    fast_scr = Scrambler.Fast.new()
    {bit, _fast_scr2} = Scrambler.Fast.next(fast_scr)
    assert bit in [0, 1], "Fast scrambler should output 0 or 1"

    # Test Fast roundtrip
    bpsk_symbols = [0, 4, 0, 0, 4, 4, 0, 4, 0, 4]
    {fast_scrambled, _} = Scrambler.Fast.scramble(Scrambler.Fast.new(), bpsk_symbols)
    {fast_descrambled, _} = Scrambler.Fast.descramble(Scrambler.Fast.new(), fast_scrambled)
    assert fast_descrambled == bpsk_symbols, "Fast scramble/descramble should roundtrip"

    IO.puts("   ✓ Scramblers OK")
  end

  def test_deep_wale_preamble do
    IO.puts("3. Testing Deep WALE preamble...")

    timing = DeepWale.frame_timing(<<0::96>>, async: false, tuner_time_ms: 0)
    assert timing.preamble_symbols == 576, "Deep preamble should be 576 symbols (240ms)"

    IO.puts("   Preamble: #{timing.preamble_symbols} symbols (#{timing.preamble_ms}ms)")
    IO.puts("   ✓ Deep WALE preamble OK")
  end

  def test_fast_wale_preamble do
    IO.puts("4. Testing Fast WALE preamble...")

    timing = FastWale.frame_timing(<<0::96>>, async: false, tuner_time_ms: 0)
    assert timing.preamble_symbols == 288, "Fast preamble should be 288 symbols (120ms)"

    IO.puts("   Preamble: #{timing.preamble_symbols} symbols (#{timing.preamble_ms}ms)")
    IO.puts("   ✓ Fast WALE preamble OK")
  end

  def test_deep_wale_data do
    IO.puts("5. Testing Deep WALE data encoding...")

    # Create a simple PDU
    pdu = %PDU.LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false
    }
    pdu_binary = PDU.encode(pdu)

    # Encode
    data_symbols = DeepWale.encode_data(pdu_binary)

    IO.puts("   PDU: #{byte_size(pdu_binary)} bytes → #{length(data_symbols)} data symbols")

    # All symbols should be 0-7 (after scrambling)
    assert Enum.all?(data_symbols, &(&1 in 0..7)), "Data symbols should be 0-7"

    # Decode back
    {recovered_dibits, _} = DeepWale.decode_data(data_symbols)
    IO.puts("   Recovered: #{length(recovered_dibits)} dibits")

    IO.puts("   ✓ Deep WALE data OK")
  end

  def test_fast_wale_data do
    IO.puts("6. Testing Fast WALE data encoding...")

    pdu = %PDU.LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false
    }
    pdu_binary = PDU.encode(pdu)

    # Encode
    data_symbols = FastWale.encode_data(pdu_binary)

    IO.puts("   PDU: #{byte_size(pdu_binary)} bytes → #{length(data_symbols)} data symbols (with probes)")

    # Decode back
    recovered_dibits = FastWale.decode_data(data_symbols)
    IO.puts("   Recovered: #{length(recovered_dibits)} dibits")

    IO.puts("   ✓ Fast WALE data OK")
  end

  def test_full_frame_assembly do
    IO.puts("7. Testing full frame assembly...")

    pdu = %PDU.LsuReq{
      caller_addr: 0x1234,
      called_addr: 0x5678,
      voice: false
    }
    pdu_binary = PDU.encode(pdu)

    # Deep WALE frame
    _deep_frame = Waveform.assemble_frame(pdu_binary,
      waveform: :deep,
      async: true,
      tuner_time_ms: 40,
      capture_probe_count: 1,
      preamble_count: 1
    )

    deep_timing = Waveform.frame_timing(pdu_binary,
      waveform: :deep,
      async: true,
      tuner_time_ms: 40
    )

    IO.puts("   Deep WALE frame:")
    IO.puts("     TLC: #{deep_timing.tlc_symbols} symbols (#{deep_timing.tlc_ms}ms)")
    IO.puts("     Capture Probe: #{deep_timing.capture_probe_symbols} symbols")
    IO.puts("     Preamble: #{deep_timing.preamble_symbols} symbols (#{deep_timing.preamble_ms}ms)")
    IO.puts("     Data: #{deep_timing.data_symbols} symbols")
    IO.puts("     Total: #{deep_timing.total_symbols} symbols (#{Float.round(deep_timing.duration_ms, 1)}ms)")

    # Fast WALE frame
    _fast_frame = Waveform.assemble_frame(pdu_binary,
      waveform: :fast,
      async: true,
      tuner_time_ms: 40,
      capture_probe_count: 1
    )

    fast_timing = Waveform.frame_timing(pdu_binary,
      waveform: :fast,
      async: true,
      tuner_time_ms: 40
    )

    IO.puts("   Fast WALE frame:")
    IO.puts("     TLC: #{fast_timing.tlc_symbols} symbols (#{fast_timing.tlc_ms}ms)")
    IO.puts("     Capture Probe: #{fast_timing.capture_probe_symbols} symbols")
    IO.puts("     Preamble: #{fast_timing.preamble_symbols} symbols (#{fast_timing.preamble_ms}ms)")
    IO.puts("     Data: #{fast_timing.data_symbols} symbols")
    IO.puts("     Total: #{fast_timing.total_symbols} symbols (#{Float.round(fast_timing.duration_ms, 1)}ms)")

    IO.puts("   ✓ Full frame assembly OK")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg) do
    IO.puts("   ✗ FAILED: #{msg}")
    raise "Assertion failed: #{msg}"
  end
end
