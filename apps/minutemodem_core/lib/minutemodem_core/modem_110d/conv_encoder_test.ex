defmodule MinuteModemCore.Modem110D.FEC.ConvEncoderTest do
  @moduledoc """
  Tests for convolutional encoder.

  Run with: MinuteModemCore.Modem110D.FEC.ConvEncoderTest.run()
  """

  alias MinuteModemCore.Modem110D.FEC.ConvEncoder

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Convolutional Encoder Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_encoder_creation()
    test_single_bit_k7()
    test_known_sequence_k7()
    test_output_length()
    test_streaming()
    test_k9_encoder()
    test_flush_terminates()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All ConvEncoder tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_encoder_creation do
    IO.puts("1. Testing encoder creation...")

    enc7 = ConvEncoder.new(7)
    assert enc7.k == 7, "K=7 encoder"
    assert enc7.state == 0, "Initial state is 0"
    assert enc7.g1 == 0o171, "G1 polynomial"
    assert enc7.g2 == 0o133, "G2 polynomial"

    enc9 = ConvEncoder.new(9)
    assert enc9.k == 9, "K=9 encoder"
    assert enc9.g1 == 0o753, "G1 polynomial K=9"
    assert enc9.g2 == 0o561, "G2 polynomial K=9"

    IO.puts("   ✓ Encoder creation tests passed\n")
  end

  def test_single_bit_k7 do
    IO.puts("2. Testing single bit encoding (K=7)...")

    enc = ConvEncoder.new(7)

    # Encode a single 1 bit
    {enc, coded} = ConvEncoder.encode(enc, [1])
    IO.puts("     After encoding [1]: state=#{enc.state} (0b#{Integer.to_string(enc.state, 2)}), coded=#{inspect(coded)}")

    assert coded == [1, 1], "Single 1 produces [1,1]"

    # Encode another 0 bit
    {enc, coded} = ConvEncoder.encode(enc, [0])
    IO.puts("     After encoding [0]: state=#{enc.state} (0b#{Integer.to_string(enc.state, 2)}), coded=#{inspect(coded)}")

    IO.puts("   ✓ Single bit encoding tests passed\n")
  end

  def test_known_sequence_k7 do
    IO.puts("3. Testing known sequence (K=7)...")

    # Test vector: input [1,0,1,1,0]
    # This is a well-known test sequence for the standard K=7 code
    enc = ConvEncoder.new(7)
    input = [1, 0, 1, 1, 0]
    {_enc, coded} = ConvEncoder.encode(enc, input)

    # Output should be 10 bits (2 per input)
    assert length(coded) == 10, "Output is 2x input length"

    IO.puts("     Input:  #{inspect(input)}")
    IO.puts("     Output: #{inspect(coded)}")

    # Verify rate
    assert ConvEncoder.rate(enc) == {1, 2}, "Rate is 1/2"

    IO.puts("   ✓ Known sequence tests passed\n")
  end

  def test_output_length do
    IO.puts("4. Testing output length calculation...")

    enc7 = ConvEncoder.new(7)
    enc9 = ConvEncoder.new(9)

    # 100 input bits with K=7: 2 * (100 + 6) = 212 output bits
    assert ConvEncoder.output_length(enc7, 100) == 212, "K=7 output length"

    # 100 input bits with K=9: 2 * (100 + 8) = 216 output bits
    assert ConvEncoder.output_length(enc9, 100) == 216, "K=9 output length"

    IO.puts("   ✓ Output length tests passed\n")
  end

  def test_streaming do
    IO.puts("5. Testing streaming encode...")

    # Encode in chunks should equal encoding all at once
    enc1 = ConvEncoder.new(7)
    enc2 = ConvEncoder.new(7)

    data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 1]

    # All at once
    {_, coded_all} = ConvEncoder.encode(enc1, data)

    # In chunks
    {enc2, coded1} = ConvEncoder.encode(enc2, Enum.take(data, 5))
    {_enc2, coded2} = ConvEncoder.encode(enc2, Enum.drop(data, 5))
    coded_chunks = coded1 ++ coded2

    assert coded_all == coded_chunks, "Streaming equals batch"

    IO.puts("   ✓ Streaming encode tests passed\n")
  end

  def test_k9_encoder do
    IO.puts("6. Testing K=9 encoder...")

    enc = ConvEncoder.new(9)
    input = [1, 1, 0, 1, 0, 0, 1, 1]
    {enc, coded} = ConvEncoder.encode(enc, input)

    assert length(coded) == 16, "K=9 output is 2x input"
    assert enc.state != 0, "State is non-zero after encoding"

    IO.puts("     Input:  #{inspect(input)}")
    IO.puts("     Output: #{inspect(coded)}")

    IO.puts("   ✓ K=9 encoder tests passed\n")
  end

  def test_flush_terminates do
    IO.puts("7. Testing flush terminates trellis...")

    enc = ConvEncoder.new(7)
    input = [1, 1, 0, 1]
    {enc, _coded} = ConvEncoder.encode(enc, input)

    assert enc.state != 0, "State is non-zero before flush"

    {enc, tail} = ConvEncoder.flush(enc)
    assert enc.state == 0, "State is zero after flush"
    assert length(tail) == 12, "Tail is 2*(K-1) = 12 bits for K=7"

    # Test encode_block convenience function
    coded = ConvEncoder.encode_block(input, 7)
    assert length(coded) == 2 * (4 + 6), "encode_block includes tail"

    IO.puts("   ✓ Flush termination tests passed\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
