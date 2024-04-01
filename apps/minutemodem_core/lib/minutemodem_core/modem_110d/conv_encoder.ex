defmodule MinuteModemCore.Modem110D.FEC.ConvEncoder do
  @moduledoc """
  Convolutional encoder for MIL-STD-188-110D.

  Supports constraint lengths K=7 and K=9 with rate 1/2.

  ## Generator Polynomials (octal)

  - K=7: G1=0o171 (0x79), G2=0o133 (0x5B) — industry standard
  - K=9: G1=0o753 (0x1EB), G2=0o561 (0x171)

  ## Full-Tail-Biting Encoding (D.5.3.2.3)

  MIL-STD-188-110D requires full-tail-biting encoding:

  1. Preload encoder with first (K-1) bits WITHOUT taking output
  2. Save those (K-1) bits for later
  3. Start taking output from the K-th bit onwards
  4. After last data bit, encode the saved (K-1) bits as "tail"
  5. Result: exactly 2× input bits (no extra length added)

  This ensures the block code fits exactly within the interleaver.

  ## Usage

      # Full-tail-biting (required for 110D)
      coded_bits = ConvEncoder.encode_tail_biting(data_bits, 7)

      # Streaming (for other uses)
      encoder = ConvEncoder.new(7)
      {encoder, coded_bits} = ConvEncoder.encode(encoder, data_bits)
      {encoder, tail_bits} = ConvEncoder.flush(encoder)
  """

  import Bitwise

  defstruct [:k, :g1, :g2, :state]

  @type t :: %__MODULE__{
          k: 7 | 9,
          g1: non_neg_integer(),
          g2: non_neg_integer(),
          state: non_neg_integer()
        }

  # Generator polynomials (octal notation in spec, stored as integers)
  # K=7: G1=171₈=0x79, G2=133₈=0x5B
  # K=9: G1=753₈=0x1EB, G2=561₈=0x171
  @generators %{
    7 => {0o171, 0o133},
    9 => {0o753, 0o561}
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Create a new convolutional encoder.

  ## Arguments
  - `k` - Constraint length (7 or 9)
  """
  def new(k) when k in [7, 9] do
    {g1, g2} = @generators[k]

    %__MODULE__{
      k: k,
      g1: g1,
      g2: g2,
      state: 0
    }
  end

  @doc """
  Encode using full-tail-biting per MIL-STD-188-110D D.5.3.2.3.

  This is the required encoding method for 110D. The encoder is preloaded
  with the first (K-1) bits, then those bits are re-encoded at the end
  to "close the loop", resulting in exactly 2×N output bits.

  ## Arguments
  - `bits` - Input data bits
  - `k` - Constraint length (7 or 9)

  ## Returns
  List of coded bits (exactly 2× input length)
  """
  def encode_tail_biting(bits, k) when k in [7, 9] and is_list(bits) do
    {g1, g2} = @generators[k]
    n = length(bits)

    if n < k do
      # For very short messages, pad to at least K bits
      padded = bits ++ List.duplicate(0, k - n)
      encode_tail_biting(padded, k)
    else
      # Step 1: Save first (K-1) bits for tail
      {preload_bits, remaining_bits} = Enum.split(bits, k - 1)

      # Step 2: Preload encoder with first (K-1) bits WITHOUT taking output
      # Build initial state from preload bits
      initial_state = preload_bits
        |> Enum.with_index()
        |> Enum.reduce(0, fn {bit, idx}, state ->
          # Shift in each bit to build state
          # First bit goes to MSB position of the (k-1) bit state
          state ||| (bit <<< (k - 2 - idx))
        end)

      # Step 3: Encode from K-th bit onwards, then all remaining bits
      # The first output comes when the K-th bit is shifted in
      all_bits_to_encode = remaining_bits ++ preload_bits

      {_final_state, coded_reversed} =
        Enum.reduce(all_bits_to_encode, {initial_state, []}, fn bit, {state, acc} ->
          # Shift new bit into register (LSB position)
          new_state = ((state <<< 1) ||| bit) &&& ((1 <<< k) - 1)

          # Compute parity outputs
          out1 = parity(new_state &&& g1)
          out2 = parity(new_state &&& g2)

          {new_state, [out2, out1 | acc]}
        end)

      Enum.reverse(coded_reversed)
    end
  end

  @doc """
  Encode a complete block with tail termination (legacy/zero-tail method).

  NOTE: This adds (K-1) zero tail bits, resulting in 2×(N + K-1) output bits.
  For MIL-STD-188-110D compliance, use `encode_tail_biting/2` instead.

  ## Arguments
  - `bits` - Input data bits
  - `k` - Constraint length (7 or 9)

  ## Returns
  List of coded bits (2 × (length(bits) + k - 1))
  """
  def encode_block(bits, k) when k in [7, 9] do
    enc = new(k)
    {enc, coded} = encode(enc, bits)
    {_enc, tail} = flush(enc)
    coded ++ tail
  end

  @doc """
  Encode a list of bits (streaming mode).

  Returns {updated_encoder, coded_bits} where coded_bits is 2x input length.
  The encoder state is updated for streaming use.
  """
  def encode(%__MODULE__{} = enc, bits) when is_list(bits) do
    {state, coded} =
      Enum.reduce(bits, {enc.state, []}, fn bit, {state, acc} ->
        # Shift new bit into register
        new_state = ((state <<< 1) ||| bit) &&& mask(enc.k)

        # Compute parity outputs
        out1 = parity(new_state &&& enc.g1)
        out2 = parity(new_state &&& enc.g2)

        {new_state, [out2, out1 | acc]}
      end)

    {%{enc | state: state}, Enum.reverse(coded)}
  end

  @doc """
  Flush the encoder with K-1 zero bits to terminate the trellis.

  This is the legacy zero-tail termination method.
  Returns {reset_encoder, tail_bits}.
  """
  def flush(%__MODULE__{} = enc) do
    tail_bits = List.duplicate(0, enc.k - 1)
    {enc, coded} = encode(enc, tail_bits)
    {%{enc | state: 0}, coded}
  end

  @doc """
  Reset encoder state to zero.
  """
  def reset(%__MODULE__{} = enc) do
    %{enc | state: 0}
  end

  @doc """
  Get the code rate as a tuple {numerator, denominator}.
  """
  def rate(%__MODULE__{}), do: {1, 2}

  @doc """
  Get the number of output bits for tail-biting encoding.
  """
  def output_length_tail_biting(input_bits) do
    # Exactly 2× input
    2 * input_bits
  end

  @doc """
  Get the number of output bits for zero-tail encoding (legacy).
  """
  def output_length(%__MODULE__{k: k}, input_bits) do
    # Each input bit produces 2 output bits
    # Plus K-1 tail bits, each producing 2 output bits
    2 * (input_bits + k - 1)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Mask for K-bit shift register
  defp mask(k), do: (1 <<< k) - 1

  # Compute parity (XOR of all bits)
  defp parity(x) do
    parity_loop(x, 0)
  end

  defp parity_loop(0, acc), do: acc
  defp parity_loop(x, acc) do
    parity_loop(x >>> 1, bxor(acc, x &&& 1))
  end
end
