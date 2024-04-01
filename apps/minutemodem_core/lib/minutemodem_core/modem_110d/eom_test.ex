defmodule MinuteModemCore.Modem110D.EOMTest do
  @moduledoc """
  Tests for End of Message (EOM) handling.

  Run with: MinuteModemCore.Modem110D.EOMTest.run()
  """

  alias MinuteModemCore.Modem110D.EOM

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("EOM Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_pattern()
    test_append()
    test_scanner_basic()
    test_scanner_finds_eom()
    test_scanner_data_before_eom()
    test_find_in()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All EOM tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_pattern do
    IO.puts("1. Testing EOM pattern...")

    pattern = EOM.pattern()
    assert length(pattern) == 32, "pattern is 32 bits"
    assert Enum.all?(pattern, &(&1 in [0, 1])), "pattern contains only 0s and 1s"

    IO.puts("   Pattern: #{EOM.pattern_as_hex()}")
    IO.puts("   ✓ Pattern tests passed\n")
  end

  def test_append do
    IO.puts("2. Testing EOM append...")

    data = [1, 0, 1, 1, 0, 0, 1, 0]
    with_eom = EOM.append(data)

    assert length(with_eom) == length(data) + 32, "appends 32 bits"
    assert Enum.take(with_eom, length(data)) == data, "data unchanged"
    assert Enum.drop(with_eom, length(data)) == EOM.pattern(), "EOM appended"

    IO.puts("   ✓ Append tests passed\n")
  end

  def test_scanner_basic do
    IO.puts("3. Testing scanner basic operation...")

    scanner = EOM.scanner_new()
    assert EOM.detected?(scanner) == false, "initially not detected"

    # Feed some random bits (not EOM)
    random_bits = for _ <- 1..100, do: Enum.random([0, 1])
    {scanner, events} = EOM.scan(scanner, random_bits)

    assert EOM.detected?(scanner) == false, "still not detected"

    # Should have data events
    data_events = Enum.filter(events, fn {type, _} -> type == :data end)
    assert length(data_events) > 0, "data events emitted"

    IO.puts("   ✓ Scanner basic tests passed\n")
  end

  def test_scanner_finds_eom do
    IO.puts("4. Testing scanner finds EOM...")

    scanner = EOM.scanner_new()

    # Send exactly the EOM pattern
    {scanner, events} = EOM.scan(scanner, EOM.pattern())

    assert EOM.detected?(scanner) == true, "EOM detected"

    eom_events = Enum.filter(events, fn {type, _} -> type == :eom_detected end)
    assert length(eom_events) == 1, "exactly one EOM event"

    {:eom_detected, idx} = hd(eom_events)
    assert idx == 0, "EOM at index 0"

    IO.puts("   ✓ Scanner finds EOM tests passed\n")
  end

  def test_scanner_data_before_eom do
    IO.puts("5. Testing scanner with data before EOM...")

    scanner = EOM.scanner_new()

    # Send some data, then EOM
    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1]  # 16 bits
    stream = data ++ EOM.pattern()

    {scanner, events} = EOM.scan(scanner, stream)

    assert EOM.detected?(scanner) == true, "EOM detected"
    assert EOM.detected_at(scanner) == 16, "EOM at bit 16"

    # Check data was emitted
    data_events = Enum.filter(events, fn {type, _} -> type == :data end)
    all_data = Enum.flat_map(data_events, fn {:data, bits} -> bits end)

    IO.puts("   Data received: #{inspect(all_data)}")
    IO.puts("   Original data: #{inspect(data)}")

    assert all_data == data, "correct data received before EOM"

    IO.puts("   ✓ Data before EOM tests passed\n")
  end

  def test_find_in do
    IO.puts("6. Testing find_in function...")

    # EOM at start
    stream1 = EOM.pattern() ++ [0, 0, 0, 0]
    assert EOM.find_in(stream1) == {:found, 0}, "finds at start"

    # EOM in middle
    prefix = [1, 1, 0, 0, 1, 0, 1, 0]
    stream2 = prefix ++ EOM.pattern() ++ [1, 1, 1, 1]
    assert EOM.find_in(stream2) == {:found, 8}, "finds in middle"

    # No EOM
    stream3 = for _ <- 1..100, do: 0
    assert EOM.find_in(stream3) == :not_found, "not found in zeros"

    IO.puts("   ✓ find_in tests passed\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
