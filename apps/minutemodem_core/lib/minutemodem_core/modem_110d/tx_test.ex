defmodule MinuteModemCore.Modem110D.TxTest do
  @moduledoc """
  Quick tests for 110D TX module.

  Run with: MinuteModemCore.Modem110D.TxTest.run()
  """

  alias MinuteModemCore.Modem110D.{Tables, Preamble, MiniProbe, Tx}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("MIL-STD-188-110D TX Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_tables()
    test_preamble()
    test_mini_probe()
    test_tx()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All 110D TX tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_tables do
    IO.puts("1. Testing Tables module...")

    # Symbol rates
    assert Tables.symbol_rate(3) == 2400, "3kHz symbol rate"
    assert Tables.symbol_rate(6) == 4800, "6kHz symbol rate"
    assert Tables.symbol_rate(24) == 19200, "24kHz symbol rate"

    # Subcarriers
    assert Tables.subcarrier(3) == 1800.0, "3kHz subcarrier"
    assert Tables.subcarrier(6) == 3300.0, "6kHz subcarrier"

    # Walsh lengths
    assert Tables.walsh_length(3) == 32, "3kHz Walsh length"
    assert Tables.walsh_length(6) == 64, "6kHz Walsh length"

    # Data/probe symbols
    assert Tables.data_symbols(6, 3) == 256, "Waveform 6, 3kHz data symbols"
    assert Tables.probe_symbols(6, 3) == 32, "Waveform 6, 3kHz probe symbols"

    # Downcount encoding
    dc = Tables.encode_downcount(0)
    assert length(dc) == 4, "Downcount length"
    assert Enum.all?(dc, &(&1 >= 0 and &1 <= 3)), "Downcount di-bits in range"

    # WID encoding
    wid = Tables.encode_wid(6, :short, 7)
    assert length(wid) == 5, "WID length"
    assert Enum.all?(wid, &(&1 >= 0 and &1 <= 3)), "WID di-bits in range"

    IO.puts("   ✓ Tables tests passed!\n")
  end

  def test_preamble do
    IO.puts("2. Testing Preamble module...")

    # Build a simple preamble
    preamble = Preamble.build(3, 6, :short, 7, m: 1, tlc_blocks: 0)

    # Check it's non-empty
    assert length(preamble) > 0, "Preamble is non-empty"

    # Check all symbols are valid 8-PSK (0-7)
    assert Enum.all?(preamble, &(&1 >= 0 and &1 <= 7)), "All symbols are 8-PSK"

    # Check length: 1 Walsh symbol (Fixed) + 4 (Count) + 5 (WID) = 10 Walsh symbols
    # At 32 chips each = 320 symbols
    expected_len = 10 * 32
    assert length(preamble) == expected_len,
      "Preamble length: expected #{expected_len}, got #{length(preamble)}"

    # Build with TLC
    preamble_with_tlc = Preamble.build(3, 6, :short, 7, m: 1, tlc_blocks: 2)
    expected_with_tlc = expected_len + 2 * 32
    assert length(preamble_with_tlc) == expected_with_tlc,
      "Preamble with TLC length"

    # Build with M > 1
    preamble_m3 = Preamble.build(3, 6, :short, 7, m: 3, tlc_blocks: 0)
    # M=3 uses 9-symbol Fixed, so: 3 * (9 + 4 + 5) * 32 = 3 * 18 * 32 = 1728
    expected_m3 = 3 * 18 * 32
    assert length(preamble_m3) == expected_m3,
      "Preamble M=3 length: expected #{expected_m3}, got #{length(preamble_m3)}"

    IO.puts("   ✓ Preamble tests passed!\n")
  end

  def test_mini_probe do
    IO.puts("3. Testing MiniProbe module...")

    # Generate 32-symbol probe (uses base-16 sequence)
    probe = MiniProbe.generate(32)
    assert length(probe) == 32, "Probe length"
    assert Enum.all?(probe, &(&1 >= 0 and &1 <= 7)), "All symbols are 8-PSK"

    # Generate shifted probe
    probe_shifted = MiniProbe.generate(32, boundary_marker: true)
    assert length(probe_shifted) == 32, "Shifted probe length"
    assert probe != probe_shifted, "Shifted probe differs from normal"

    # Generate for waveform
    probe_wf = MiniProbe.generate_for_waveform(6, 3)
    assert length(probe_wf) == 32, "Waveform 6, 3kHz probe length"

    IO.puts("   ✓ MiniProbe tests passed!\n")
  end

  def test_tx do
    IO.puts("4. Testing Tx module...")

    # Create some dummy data symbols (already encoded)
    # Waveform 6 at 3kHz has U=256 data symbols per block
    data_symbols = Enum.map(1..256, fn i -> rem(i, 8) end)

    # Build symbol stream
    symbols = Tx.build_symbol_stream(data_symbols, 6, 3, :short, 7, m: 1)

    assert length(symbols) > 0, "Symbol stream is non-empty"
    assert Enum.all?(symbols, &(&1 >= 0 and &1 <= 7)), "All symbols are 8-PSK"

    # Check structure: preamble + initial_probe + (data_block + probe)
    # Preamble: 10 * 32 = 320
    # Initial probe: 32
    # Data block: 256
    # Final probe: 32
    expected = 320 + 32 + 256 + 32
    assert length(symbols) == expected,
      "Symbol stream length: expected #{expected}, got #{length(symbols)}"

    # Test duration calculation
    duration = Tx.duration_ms(expected, 3)
    assert duration > 0, "Duration is positive"
    IO.puts("   Duration: #{Float.round(duration, 1)} ms")

    IO.puts("   ✓ Tx tests passed!\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise "Assertion failed: #{msg}"
end
