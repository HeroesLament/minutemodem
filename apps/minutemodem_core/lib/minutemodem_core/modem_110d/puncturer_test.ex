defmodule MinuteModemCore.Modem110D.FEC.PuncturerTest do
  @moduledoc """
  Tests for puncturing and depuncturing.

  Run with: MinuteModemCore.Modem110D.FEC.PuncturerTest.run()
  """

  alias MinuteModemCore.Modem110D.FEC.{Puncturer, ConvEncoder, Viterbi}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Puncturer Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_patterns()
    test_rate_half_passthrough()
    test_rate_three_quarters()
    test_length_calculation()
    test_depuncture_inserts_erasures()
    test_full_fec_chain_rate_half()
    test_full_fec_chain_rate_three_quarters()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All Puncturer tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_patterns do
    IO.puts("1. Testing puncture patterns...")

    assert Puncturer.get_pattern({1, 2}) == [1, 1], "rate 1/2 pattern"
    assert Puncturer.get_pattern({3, 4}) == [1, 1, 0, 1], "rate 3/4 pattern"
    assert Puncturer.get_pattern({7, 8}) == [1, 1, 0, 1, 1, 0, 1, 1], "rate 7/8 pattern"

    IO.puts("   ✓ Pattern tests passed\n")
  end

  def test_rate_half_passthrough do
    IO.puts("2. Testing rate 1/2 (no puncturing)...")

    bits = [1, 0, 1, 1, 0, 0, 1, 0]
    punctured = Puncturer.puncture(bits, {1, 2})

    assert punctured == bits, "rate 1/2 keeps all bits"

    IO.puts("   ✓ Rate 1/2 passthrough test passed\n")
  end

  def test_rate_three_quarters do
    IO.puts("3. Testing rate 3/4 puncturing...")

    # Pattern [1, 1, 0, 1] means keep positions 0, 1, 3; delete position 2
    bits = [1, 0, 1, 1,  0, 0, 1, 0]
    #       ^  ^  X  ^   ^  ^  X  ^   (X = deleted)

    punctured = Puncturer.puncture(bits, {3, 4})

    # Should keep: 1, 0, 1, 0, 0, 0
    expected = [1, 0, 1, 0, 0, 0]
    assert punctured == expected, "rate 3/4 removes correct bits"
    assert length(punctured) == 6, "6 bits kept from 8"

    IO.puts("     Input:     #{inspect(bits)}")
    IO.puts("     Punctured: #{inspect(punctured)}")
    IO.puts("   ✓ Rate 3/4 puncturing test passed\n")
  end

  def test_length_calculation do
    IO.puts("4. Testing length calculations...")

    # Rate 1/2: keep all
    assert Puncturer.punctured_length(100, {1, 2}) == 100, "rate 1/2 length"

    # Rate 3/4: keep 3 of every 4
    assert Puncturer.punctured_length(100, {3, 4}) == 75, "rate 3/4 length"

    # Rate 7/8: keep 6 of every 8
    assert Puncturer.punctured_length(100, {7, 8}) == 75, "rate 7/8 length"

    IO.puts("   ✓ Length calculation tests passed\n")
  end

  def test_depuncture_inserts_erasures do
    IO.puts("5. Testing depuncture inserts erasures...")

    # Simulate received soft values (after puncturing at rate 3/4)
    soft = [1.0, -1.0, 0.5,  0.8, -0.9, 0.3]
    #       pos0  pos1 pos3  pos4  pos5 pos7  (positions 2, 6 were punctured)

    depunctured = Puncturer.depuncture(soft, {3, 4})

    # Should have erasures at positions 2 and 6
    expected = [1.0, -1.0, 0.0, 0.5, 0.8, -0.9, 0.0, 0.3]

    assert depunctured == expected, "erasures inserted correctly"

    IO.puts("     Punctured soft: #{inspect(soft)}")
    IO.puts("     Depunctured:    #{inspect(depunctured)}")
    IO.puts("   ✓ Depuncture erasure test passed\n")
  end

  def test_full_fec_chain_rate_half do
    IO.puts("6. Testing full FEC chain (rate 1/2)...")

    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1]

    # TX: Encode -> Puncture (rate 1/2 = no change)
    coded = ConvEncoder.encode_block(data, 7)
    punctured = Puncturer.puncture(coded, {1, 2})

    # RX: Depuncture -> Decode
    depunctured = Puncturer.depuncture(hard_to_soft(punctured), {1, 2})
    decoded = Viterbi.decode_soft(depunctured, 7)
    recovered = Enum.take(decoded, length(data))

    assert recovered == data, "full chain rate 1/2 roundtrip"

    IO.puts("   ✓ Full FEC chain (rate 1/2) passed\n")
  end

  def test_full_fec_chain_rate_three_quarters do
    IO.puts("7. Testing full FEC chain (rate 3/4)...")

    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1]

    # TX: Encode -> Puncture
    coded = ConvEncoder.encode_block(data, 7)
    punctured = Puncturer.puncture(coded, {3, 4})

    IO.puts("     Data length:      #{length(data)}")
    IO.puts("     Coded length:     #{length(coded)}")
    IO.puts("     Punctured length: #{length(punctured)}")

    # RX: Depuncture -> Decode
    soft = hard_to_soft(punctured)
    depunctured = Puncturer.depuncture(soft, {3, 4})

    IO.puts("     Depunctured length: #{length(depunctured)}")

    decoded = Viterbi.decode_soft(depunctured, 7)
    recovered = Enum.take(decoded, length(data))

    IO.puts("     Decoded: #{inspect(recovered)}")
    IO.puts("     Data:    #{inspect(data)}")

    assert recovered == data, "full chain rate 3/4 roundtrip"

    IO.puts("   ✓ Full FEC chain (rate 3/4) passed\n")
  end

  # Convert hard bits to soft values
  defp hard_to_soft(bits) do
    Enum.map(bits, fn
      0 -> 1.0
      1 -> -1.0
    end)
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
