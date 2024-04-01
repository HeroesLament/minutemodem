defmodule MinuteModemCore.Modem110D.Downcount do
  @moduledoc """
  Decoded Downcount from 110D preamble super-frame.

  The downcount is transmitted as 4 Walsh-modulated di-bits (c3..c0) encoding:
  - 5-bit count (0-31), decremented each super-frame
  - 3 parity bits

  When count reaches 0, data begins in the next frame.

  ## Usage

      case Downcount.decode(dibits) do
        {:ok, %Downcount{count: 0}} ->
          # This is the last super-frame, data follows
          :data_next

        {:ok, %Downcount{count: n}} ->
          # n more super-frames before data
          {:waiting, n}

        {:error, :parity_mismatch} ->
          # Corrupted, may need to re-acquire
          :resync
      end
  """

  @enforce_keys [:count]
  defstruct [:count, :raw_bits]

  @type t :: %__MODULE__{
          count: 0..31,
          raw_bits: [0 | 1] | nil
        }

  import Bitwise

  @doc """
  Decode downcount from 4 di-bits (c3, c2, c1, c0).

  ## Arguments
  - `dibits` - List of 4 di-bits [c3, c2, c1, c0], each 0-3

  ## Returns
  - `{:ok, %Downcount{}}` on successful decode with valid parity
  - `{:error, :parity_mismatch}` if parity fails
  """
  def decode([c3, c2, c1, c0] = dibits) when length(dibits) == 4 do
    # Extract bits from di-bits
    # c3 = {b7, b6}, c2 = {b5, b4}, c1 = {b3, b2}, c0 = {b1, b0}
    b7 = (c3 >>> 1) &&& 1
    b6 = c3 &&& 1
    b5 = (c2 >>> 1) &&& 1
    b4 = c2 &&& 1
    b3 = (c1 >>> 1) &&& 1
    b2 = c1 &&& 1
    b1 = (c0 >>> 1) &&& 1
    b0 = c0 &&& 1

    # Verify parity
    # b7 = b1 ⊕ b2 ⊕ b3
    # b6 = b2 ⊕ b3 ⊕ b4
    # b5 = b0 ⊕ b1 ⊕ b2
    expected_b7 = bxor(b1, bxor(b2, b3))
    expected_b6 = bxor(b2, bxor(b3, b4))
    expected_b5 = bxor(b0, bxor(b1, b2))

    if b7 == expected_b7 and b6 == expected_b6 and b5 == expected_b5 do
      # Reconstruct count: b4 b3 b2 b1 b0
      count = (b4 <<< 4) ||| (b3 <<< 3) ||| (b2 <<< 2) ||| (b1 <<< 1) ||| b0

      {:ok,
       %__MODULE__{
         count: count,
         raw_bits: [b7, b6, b5, b4, b3, b2, b1, b0]
       }}
    else
      {:error, :parity_mismatch}
    end
  end

  def decode(_), do: {:error, :invalid_input}

  @doc """
  Encode a count value to 4 di-bits for transmission.

  Uses Tables.encode_downcount/1 internally.
  """
  def encode(count) when count in 0..31 do
    MinuteModemCore.Modem110D.Tables.encode_downcount(count)
  end

  @doc """
  Check if this is the final super-frame (count = 0).
  """
  def final?(%__MODULE__{count: 0}), do: true
  def final?(%__MODULE__{}), do: false

  @doc """
  Get number of remaining super-frames after this one.
  """
  def remaining(%__MODULE__{count: n}), do: n

  defimpl Inspect do
    def inspect(%MinuteModemCore.Modem110D.Downcount{count: c}, _opts) do
      "#Downcount<#{c}>"
    end
  end
end
