defmodule MinuteModemCore.ALE.Encoding do
  @moduledoc """
  MIL-STD-188-141D 4G ALE Forward Error Correction encoding.

  Implements:
  - Rate 1/2 convolutional encoder (K=7)
  - Block interleaver

  The convolutional encoder uses generator polynomials:
  - G1 = 0b1011011 (octal 133)
  - G2 = 0b1111001 (octal 171)

  Output is 2 bits per input bit (rate 1/2).
  """

  import Bitwise

  # Generator polynomials (constraint length K=7)
  # G1 = 1 + D + D^2 + D^3 + D^6 = 0b1011011 = 91
  # G2 = 1 + D^2 + D^3 + D^5 + D^6 = 0b1111001 = 121
  @g1 0b1011011
  @g2 0b1111001
  @constraint_length 7
  @register_mask (1 <<< @constraint_length) - 1

  # -------------------------------------------------------------------
  # Convolutional Encoder
  # -------------------------------------------------------------------

  @doc """
  Encode data using rate 1/2 convolutional code.

  Takes a binary and returns a list of dibits (0-3).
  Each input bit produces one dibit (2 output bits).

  ## Example

      iex> Encoding.conv_encode(<<0b10110100>>)
      [3, 0, 2, 1, 1, 3, 2, 0]  # Example output
  """
  def conv_encode(data) when is_binary(data) do
    data
    |> binary_to_bits()
    |> conv_encode_bits(0, [])
    |> Enum.reverse()
  end

  defp conv_encode_bits([], _register, acc), do: acc

  defp conv_encode_bits([bit | rest], register, acc) do
    # Shift in the new bit
    new_register = ((register <<< 1) ||| bit) &&& @register_mask

    # Compute output bits using generator polynomials
    out1 = parity(new_register &&& @g1)
    out2 = parity(new_register &&& @g2)

    # Combine into dibit (0-3)
    dibit = (out1 <<< 1) ||| out2

    conv_encode_bits(rest, new_register, [dibit | acc])
  end

  @doc """
  Flush the encoder with tail bits.

  After encoding data, flush with K-1 zero bits to return
  the encoder to the zero state. Returns the flush dibits.
  """
  def conv_flush(register) do
    # Flush with K-1 = 6 zero bits
    {dibits, _final_register} =
      Enum.reduce(1..(@constraint_length - 1), {[], register}, fn _, {acc, reg} ->
        new_reg = (reg <<< 1) &&& @register_mask
        out1 = parity(new_reg &&& @g1)
        out2 = parity(new_reg &&& @g2)
        dibit = (out1 <<< 1) ||| out2
        {[dibit | acc], new_reg}
      end)

    Enum.reverse(dibits)
  end

  @doc """
  Encode with flush - encodes data and appends tail bits.
  """
  def conv_encode_with_flush(data) when is_binary(data) do
    bits = binary_to_bits(data)
    {dibits, final_register} = conv_encode_bits_with_register(bits, 0, [])
    flush_dibits = conv_flush(final_register)
    Enum.reverse(dibits) ++ flush_dibits
  end

  defp conv_encode_bits_with_register([], register, acc), do: {acc, register}

  defp conv_encode_bits_with_register([bit | rest], register, acc) do
    new_register = ((register <<< 1) ||| bit) &&& @register_mask
    out1 = parity(new_register &&& @g1)
    out2 = parity(new_register &&& @g2)
    dibit = (out1 <<< 1) ||| out2
    conv_encode_bits_with_register(rest, new_register, [dibit | acc])
  end

  # -------------------------------------------------------------------
  # Interleaver
  # -------------------------------------------------------------------

  @doc """
  Interleave a list of symbols using block interleaving.

  The interleaver writes symbols row-by-row into a matrix,
  then reads them column-by-column.

  ## Parameters

  - `symbols` - List of symbols to interleave
  - `rows` - Number of rows in interleaver matrix
  - `cols` - Number of columns in interleaver matrix

  The total capacity is rows * cols. Input is padded with zeros
  if shorter, or truncated if longer.
  """
  def interleave(symbols, rows, cols) do
    capacity = rows * cols

    # Pad or truncate to fit matrix
    padded =
      symbols
      |> Enum.take(capacity)
      |> then(fn s ->
        pad_length = capacity - length(s)
        s ++ List.duplicate(0, pad_length)
      end)

    # Write row-by-row, read column-by-column
    matrix =
      padded
      |> Enum.chunk_every(cols)

    for col <- 0..(cols - 1),
        row <- 0..(rows - 1) do
      matrix |> Enum.at(row) |> Enum.at(col)
    end
  end

  @doc """
  De-interleave symbols (inverse of interleave).
  """
  def deinterleave(symbols, rows, cols) do
    capacity = rows * cols

    padded =
      symbols
      |> Enum.take(capacity)
      |> then(fn s ->
        pad_length = capacity - length(s)
        s ++ List.duplicate(0, pad_length)
      end)

    # Write column-by-column, read row-by-row
    matrix =
      padded
      |> Enum.chunk_every(rows)

    for row <- 0..(rows - 1),
        col <- 0..(cols - 1) do
      matrix |> Enum.at(col) |> Enum.at(row)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp binary_to_bits(data) do
    for <<byte <- data>>,
        bit <- 7..0//-1 do
      (byte >>> bit) &&& 1
    end
  end

  defp parity(value) do
    # Count 1 bits, return 0 if even, 1 if odd
    value
    |> Integer.digits(2)
    |> Enum.sum()
    |> rem(2)
  end

  # -------------------------------------------------------------------
  # Dibit to Tribit Mapping (for 8-PSK)
  # -------------------------------------------------------------------

  @doc """
  Map dibits to tribits for 8-PSK modulation.

  4G ALE uses 8-PSK, which needs 3 bits per symbol (tribit).
  This function groups dibits and maps to tribits according
  to the spec.

  Takes a list of dibits (0-3) and returns a list of tribits (0-7).
  """
  def dibits_to_tribits(dibits) do
    # Group dibits into pairs, map each pair to 3 tribits
    # This is a 4:3 mapping (4 dibits = 8 bits → 3 tribits = 9 bits, with padding)

    # Actually, the spec defines specific mapping tables.
    # For now, simple bit concatenation and re-chunking:
    bits =
      dibits
      |> Enum.flat_map(fn dibit ->
        [(dibit >>> 1) &&& 1, dibit &&& 1]
      end)

    # Chunk into groups of 3 bits, pad if needed
    bits
    |> Enum.chunk_every(3, 3, [0, 0])
    |> Enum.map(fn [b2, b1, b0] ->
      (b2 <<< 2) ||| (b1 <<< 1) ||| b0
    end)
  end

  @doc """
  Full encoding pipeline: PDU binary → symbol indices ready for modulator.

  1. Convolutional encode (rate 1/2)
  2. Interleave
  3. Map to tribits (8-PSK symbols)
  """
  def encode_pdu(pdu_binary, interleaver_rows \\ 12, interleaver_cols \\ 16) do
    pdu_binary
    |> conv_encode_with_flush()
    |> interleave(interleaver_rows, interleaver_cols)
    |> dibits_to_tribits()
  end
end
