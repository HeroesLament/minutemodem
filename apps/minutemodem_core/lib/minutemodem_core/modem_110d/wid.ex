defmodule MinuteModemCore.Modem110D.WID do
  @moduledoc """
  Decoded Waveform ID from 110D preamble.

  The WID is transmitted as 5 Walsh-modulated di-bits (w4..w0) encoding:
  - Waveform number (0-13)
  - Interleaver option (ultra_short, short, medium, long)
  - Constraint length (7 or 9)
  - 3-bit checksum

  This struct represents the fully decoded and validated WID.

  ## Usage

      case WID.decode(dibits) do
        {:ok, %WID{} = wid} ->
          # Configure receiver
          constellation = WID.constellation(wid)
          frame_params = WID.frame_params(wid, bandwidth)

        {:error, :checksum_mismatch} ->
          # Retry or abort
      end
  """

  alias MinuteModemCore.Modem110D.Tables

  @enforce_keys [:waveform, :interleaver, :constraint_length]
  defstruct [
    :waveform,
    :interleaver,
    :constraint_length,
    :raw_bits
  ]

  @type interleaver :: :ultra_short | :short | :medium | :long
  @type constraint :: 7 | 9

  @type t :: %__MODULE__{
          waveform: 0..13,
          interleaver: interleaver(),
          constraint_length: constraint(),
          raw_bits: [0 | 1] | nil
        }

  import Bitwise

  # ===========================================================================
  # Decoding
  # ===========================================================================

  @doc """
  Decode WID from 5 di-bits (w4, w3, w2, w1, w0).

  ## Arguments
  - `dibits` - List of 5 di-bits [w4, w3, w2, w1, w0], each 0-3

  ## Returns
  - `{:ok, %WID{}}` on successful decode with valid checksum
  - `{:error, :checksum_mismatch}` if checksum fails
  - `{:error, :invalid_waveform}` if waveform number is reserved
  """
  def decode([w4, w3, w2, w1, w0] = dibits) when length(dibits) == 5 do
    # Extract bits from di-bits
    d9 = (w4 >>> 1) &&& 1
    d8 = w4 &&& 1
    d7 = (w3 >>> 1) &&& 1
    d6 = w3 &&& 1
    d5 = (w2 >>> 1) &&& 1
    d4 = w2 &&& 1
    d3 = (w1 >>> 1) &&& 1
    d2 = w1 &&& 1
    d1 = (w0 >>> 1) &&& 1
    d0 = w0 &&& 1

    # Verify checksum
    expected_d2 = bxor(d9, bxor(d8, d7))
    expected_d1 = bxor(d7, bxor(d6, d5))
    expected_d0 = bxor(d5, bxor(d4, d3))

    if d2 == expected_d2 and d1 == expected_d1 and d0 == expected_d0 do
      # Decode fields
      waveform = (d9 <<< 3) ||| (d8 <<< 2) ||| (d7 <<< 1) ||| d6
      interleaver = decode_interleaver(d5, d4)
      constraint_length = if d3 == 1, do: 9, else: 7

      # Check for reserved waveform numbers
      if waveform in 14..15 do
        {:error, :invalid_waveform}
      else
        {:ok,
         %__MODULE__{
           waveform: waveform,
           interleaver: interleaver,
           constraint_length: constraint_length,
           raw_bits: [d9, d8, d7, d6, d5, d4, d3, d2, d1, d0]
         }}
      end
    else
      {:error, :checksum_mismatch}
    end
  end

  def decode(_), do: {:error, :invalid_input}

  defp decode_interleaver(0, 0), do: :ultra_short
  defp decode_interleaver(0, 1), do: :short
  defp decode_interleaver(1, 0), do: :medium
  defp decode_interleaver(1, 1), do: :long

  # ===========================================================================
  # Derived Properties
  # ===========================================================================

  @doc """
  Get the modulation/constellation type for this waveform.

  ## Returns
  Atom: :walsh, :bpsk, :qpsk, :psk8, :qam16, :qam32, :qam64, :qam256
  """
  def constellation(%__MODULE__{waveform: wf}) do
    Tables.modulation(wf)
  end

  @doc """
  Get bits per symbol for this waveform.
  """
  def bits_per_symbol(%__MODULE__{} = wid) do
    wid |> constellation() |> Tables.bits_per_symbol()
  end

  @doc """
  Get the FEC code rate for this waveform.

  ## Returns
  Tuple `{numerator, denominator}` representing the code rate.

  Per MIL-STD-188-110D Table D-II:
  - WF 0-6: Rate 1/2
  - WF 7-9: Rate 3/4
  - WF 10-12: Rate 7/8
  """
  def code_rate(%__MODULE__{waveform: wf}) when wf in 0..6, do: {1, 2}
  def code_rate(%__MODULE__{waveform: wf}) when wf in 7..9, do: {3, 4}
  def code_rate(%__MODULE__{waveform: wf}) when wf in 10..12, do: {7, 8}
  def code_rate(%__MODULE__{}), do: {1, 2}  # Default

  @doc """
  Get frame parameters for this waveform at given bandwidth.

  ## Returns
  Map with :data_symbols (U) and :probe_symbols (K)
  """
  def frame_params(%__MODULE__{waveform: wf}, bw_khz) do
    %{
      data_symbols: Tables.data_symbols(wf, bw_khz),
      probe_symbols: Tables.probe_symbols(wf, bw_khz)
    }
  end

  @doc """
  Check if this is a Walsh-based waveform (WF 0).
  """
  def walsh?(%__MODULE__{waveform: 0}), do: true
  def walsh?(%__MODULE__{}), do: false

  @doc """
  Check if this waveform uses PSK modulation (no amplitude component).
  """
  def psk?(%__MODULE__{waveform: wf}) when wf in 0..6, do: true
  def psk?(%__MODULE__{}), do: false

  @doc """
  Check if this waveform uses QAM modulation.
  """
  def qam?(%__MODULE__{} = wid), do: not psk?(wid)

  # ===========================================================================
  # Encoding (for TX)
  # ===========================================================================

  @doc """
  Create a WID struct from parameters.

  ## Arguments
  - `waveform` - Waveform number (0-13)
  - `interleaver` - :ultra_short, :short, :medium, :long
  - `constraint_length` - 7 or 9

  ## Returns
  `%WID{}` struct
  """
  def new(waveform, interleaver, constraint_length)
      when waveform in 0..13 and
             interleaver in [:ultra_short, :short, :medium, :long] and
             constraint_length in [7, 9] do
    %__MODULE__{
      waveform: waveform,
      interleaver: interleaver,
      constraint_length: constraint_length
    }
  end

  @doc """
  Encode WID to 5 di-bits for transmission.

  Uses Tables.encode_wid/3 internally.
  """
  def encode(%__MODULE__{waveform: wf, interleaver: ilv, constraint_length: k}) do
    Tables.encode_wid(wf, ilv, k)
  end

  # ===========================================================================
  # String Representation
  # ===========================================================================

  defimpl String.Chars do
    def to_string(%MinuteModemCore.Modem110D.WID{} = wid) do
      mod = MinuteModemCore.Modem110D.WID.constellation(wid)
      "WID{wf=#{wid.waveform}, #{mod}, #{wid.interleaver}, K=#{wid.constraint_length}}"
    end
  end

  defimpl Inspect do
    def inspect(%MinuteModemCore.Modem110D.WID{} = wid, _opts) do
      mod = MinuteModemCore.Modem110D.WID.constellation(wid)

      "#WID<wf#{wid.waveform} #{mod} #{wid.interleaver} K#{wid.constraint_length}>"
    end
  end
end
