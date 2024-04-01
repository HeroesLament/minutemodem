defmodule MinuteModemCore.Modem110D.FEC.InterleaverTest do
  @moduledoc """
  Tests for the block interleaver.

  Run with: MinuteModemCore.Modem110D.FEC.InterleaverTest.run()
  """

  alias MinuteModemCore.Modem110D.FEC.Interleaver

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Interleaver Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_dimensions()
    test_roundtrip()
    test_spreading()
    test_burst_error_spreading()
    test_all_types()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All Interleaver tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_dimensions do
    IO.puts("1. Testing interleaver dimensions...")

    assert Interleaver.get_dimensions(3, :ultra_short) == {9, 40}, "ultra_short 3kHz"
    assert Interleaver.get_dimensions(3, :short) == {9, 256}, "short 3kHz"
    assert Interleaver.get_dimensions(3, :medium) == {9, 1024}, "medium 3kHz"
    assert Interleaver.get_dimensions(3, :long) == {9, 2048}, "long 3kHz"

    assert Interleaver.block_size(3, :ultra_short) == 360, "block size ultra_short"
    assert Interleaver.block_size(3, :short) == 2304, "block size short"

    IO.puts("   ✓ Dimensions tests passed\n")
  end

  def test_roundtrip do
    IO.puts("2. Testing interleave/deinterleave roundtrip...")

    # Generate test data exactly one block size
    block_size = Interleaver.block_size(3, :ultra_short)
    data = for i <- 1..block_size, do: rem(i, 2)

    interleaved = Interleaver.interleave(data, :ultra_short)
    deinterleaved = Interleaver.deinterleave(interleaved, :ultra_short)

    assert length(interleaved) == block_size, "interleaved length"
    assert length(deinterleaved) == block_size, "deinterleaved length"
    assert deinterleaved == data, "roundtrip matches"

    IO.puts("   ✓ Roundtrip test passed\n")
  end

  def test_spreading do
    IO.puts("3. Testing that interleaving spreads adjacent bits...")

    # Create data where first 9 bits are 1, rest are 0
    # After interleaving, these should be spread across columns
    {rows, cols} = Interleaver.get_dimensions(3, :ultra_short)
    block_size = rows * cols

    data = List.duplicate(1, rows) ++ List.duplicate(0, block_size - rows)
    interleaved = Interleaver.interleave(data, :ultra_short)

    # The first row's bits should now be at positions 0, rows, 2*rows, etc.
    # i.e., every 'rows'th position should have a 1
    ones_positions =
      interleaved
      |> Enum.with_index()
      |> Enum.filter(fn {bit, _idx} -> bit == 1 end)
      |> Enum.map(fn {_bit, idx} -> idx end)

    # First 9 ones should be at positions 0, 9, 18, 27, ... (every 9th position)
    expected_positions = for i <- 0..(cols - 1), do: i * rows
    expected_positions = Enum.take(expected_positions, rows)

    assert ones_positions == expected_positions, "bits spread to expected positions"

    IO.puts("     First row bits spread to positions: #{inspect(Enum.take(ones_positions, 5))}...")
    IO.puts("   ✓ Spreading test passed\n")
  end

  def test_burst_error_spreading do
    IO.puts("4. Testing burst error spreading...")

    {rows, cols} = Interleaver.get_dimensions(3, :ultra_short)
    block_size = rows * cols

    # Create clean data
    original = for i <- 1..block_size, do: rem(i, 2)
    interleaved = Interleaver.interleave(original, :ultra_short)

    # Simulate a burst error: corrupt 9 consecutive bits in the interleaved stream
    burst_start = 100
    burst_length = 9

    corrupted =
      interleaved
      |> Enum.with_index()
      |> Enum.map(fn {bit, idx} ->
        if idx >= burst_start and idx < burst_start + burst_length do
          1 - bit  # Flip the bit
        else
          bit
        end
      end)

    # Deinterleave
    deinterleaved = Interleaver.deinterleave(corrupted, :ultra_short)

    # Count errors and their positions
    errors =
      Enum.zip(original, deinterleaved)
      |> Enum.with_index()
      |> Enum.filter(fn {{a, b}, _idx} -> a != b end)
      |> Enum.map(fn {_, idx} -> idx end)

    IO.puts("     Burst of #{burst_length} errors at interleaved pos #{burst_start}")
    IO.puts("     After deinterleave, errors at positions: #{inspect(errors)}")

    # Errors should be spread apart by approximately 'cols' positions
    assert length(errors) == burst_length, "same number of errors"

    # Check that errors are spread apart (should be close to cols apart)
    if length(errors) > 1 do
      gaps = errors |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      min_gap = Enum.min(gaps)
      IO.puts("     Minimum gap between errors: #{min_gap} (interleaver cols: #{cols})")
      # Gap should be close to cols (within a few positions due to row structure)
      assert min_gap >= cols - rows, "errors spread apart significantly"
    end

    IO.puts("   ✓ Burst error spreading test passed\n")
  end

  def test_all_types do
    IO.puts("5. Testing all interleaver types...")

    for type <- [:ultra_short, :short, :medium, :long] do
      block_size = Interleaver.block_size(3, type)
      # Use smaller test data for larger interleavers
      test_size = min(block_size, 1000)
      data = for i <- 1..test_size, do: rem(i, 2)

      interleaved = Interleaver.interleave(data, type)
      deinterleaved = Interleaver.deinterleave(interleaved, type)

      # Trim to original size (may have been padded)
      recovered = Enum.take(deinterleaved, test_size)

      assert recovered == data, "#{type} roundtrip"

      latency = Interleaver.latency_seconds(3, type)
      IO.puts("     #{type}: block=#{block_size} bits, latency=#{Float.round(latency, 2)}s ✓")
    end

    IO.puts("   ✓ All types test passed\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
