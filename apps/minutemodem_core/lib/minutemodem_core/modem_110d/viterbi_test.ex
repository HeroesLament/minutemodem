defmodule MinuteModemCore.Modem110D.FEC.ViterbiTest do
  @moduledoc """
  Tests for Viterbi decoder.

  Run with: MinuteModemCore.Modem110D.FEC.ViterbiTest.run()
  """

  alias MinuteModemCore.Modem110D.FEC.{ConvEncoder, Viterbi}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Viterbi Decoder Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_simple_roundtrip_k7()
    test_simple_roundtrip_k9()
    test_all_zeros()
    test_all_ones()
    test_longer_sequence()
    test_hard_decision_errors()
    test_soft_decision_advantage()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All Viterbi tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_simple_roundtrip_k7 do
    IO.puts("1. Testing simple roundtrip K=7...")

    data = [1, 0, 1, 1, 0, 0, 1, 0]
    coded = ConvEncoder.encode_block(data, 7)

    IO.puts("     Data:    #{inspect(data)}")
    IO.puts("     Coded:   #{inspect(coded)} (#{length(coded)} bits)")

    decoded = Viterbi.decode(coded, 7)

    IO.puts("     Decoded: #{inspect(decoded)} (#{length(decoded)} bits)")

    # Decoded includes tail bits, so take only data length
    decoded_data = Enum.take(decoded, length(data))

    IO.puts("     Trimmed: #{inspect(decoded_data)}")

    assert decoded_data == data, "K=7 roundtrip matches"

    IO.puts("   ✓ Simple roundtrip K=7 passed\n")
  end

  def test_simple_roundtrip_k9 do
    IO.puts("2. Testing simple roundtrip K=9...")

    data = [1, 1, 0, 0, 1, 0, 1, 1]
    coded = ConvEncoder.encode_block(data, 9)
    decoded = Viterbi.decode(coded, 9)
    decoded_data = Enum.take(decoded, length(data))

    IO.puts("     Data:    #{inspect(data)}")
    IO.puts("     Decoded: #{inspect(decoded_data)}")

    assert decoded_data == data, "K=9 roundtrip matches"

    IO.puts("   ✓ Simple roundtrip K=9 passed\n")
  end

  def test_all_zeros do
    IO.puts("3. Testing all zeros...")

    data = List.duplicate(0, 20)
    coded = ConvEncoder.encode_block(data, 7)
    decoded = Viterbi.decode(coded, 7)
    decoded_data = Enum.take(decoded, length(data))

    assert decoded_data == data, "All zeros roundtrip"

    IO.puts("   ✓ All zeros test passed\n")
  end

  def test_all_ones do
    IO.puts("4. Testing all ones...")

    data = List.duplicate(1, 20)
    coded = ConvEncoder.encode_block(data, 7)
    decoded = Viterbi.decode(coded, 7)
    decoded_data = Enum.take(decoded, length(data))

    assert decoded_data == data, "All ones roundtrip"

    IO.puts("   ✓ All ones test passed\n")
  end

  def test_longer_sequence do
    IO.puts("5. Testing longer random sequence...")

    # Generate pseudo-random data
    :rand.seed(:exsss, {1, 2, 3})
    data = for _ <- 1..100, do: :rand.uniform(2) - 1

    coded = ConvEncoder.encode_block(data, 7)
    decoded = Viterbi.decode(coded, 7)
    decoded_data = Enum.take(decoded, length(data))

    assert decoded_data == data, "100-bit random sequence roundtrip"

    IO.puts("   ✓ Longer sequence test passed (100 bits)\n")
  end

  def test_hard_decision_errors do
    IO.puts("6. Testing error correction (hard decision)...")

    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1]
    coded = ConvEncoder.encode_block(data, 7)

    # Introduce some bit errors
    error_positions = [3, 12, 25]  # Flip these bits
    corrupted =
      coded
      |> Enum.with_index()
      |> Enum.map(fn {bit, idx} ->
        if idx in error_positions, do: 1 - bit, else: bit
      end)

    errors_introduced = length(error_positions)
    IO.puts("     Introduced #{errors_introduced} bit errors")

    decoded = Viterbi.decode(corrupted, 7)
    decoded_data = Enum.take(decoded, length(data))

    bit_errors = Enum.zip(data, decoded_data) |> Enum.count(fn {a, b} -> a != b end)
    IO.puts("     Bit errors after decoding: #{bit_errors}")

    # With rate 1/2 K=7, should correct scattered errors
    assert bit_errors < errors_introduced, "Errors reduced by decoding"

    IO.puts("   ✓ Error correction test passed\n")
  end

  def test_soft_decision_advantage do
    IO.puts("7. Testing soft decision advantage...")

    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1]
    coded = ConvEncoder.encode_block(data, 7)

    # Convert to soft values with some noise
    :rand.seed(:exsss, {42, 42, 42})
    soft = Enum.map(coded, fn bit ->
      # Base value: 0 -> +1.0, 1 -> -1.0
      base = if bit == 0, do: 1.0, else: -1.0
      # Add noise
      noise = (:rand.uniform() - 0.5) * 1.0
      base + noise
    end)

    # Decode with soft values
    decoded_soft = Viterbi.decode_soft(soft, 7)
    decoded_data = Enum.take(decoded_soft, length(data))

    bit_errors = Enum.zip(data, decoded_data) |> Enum.count(fn {a, b} -> a != b end)
    IO.puts("     Soft decode bit errors: #{bit_errors}")

    assert decoded_data == data, "Soft decode recovers data"

    IO.puts("   ✓ Soft decision test passed\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
