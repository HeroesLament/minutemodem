defmodule MinuteModemCore.DSP.DemodOutput do
  @moduledoc """
  Algebraic data type for demodulator output.

  Supports both hard symbol decisions and soft I/Q samples,
  enabling deferred slicing for 110D receiver.

  ## Variants

  - `%DemodOutput.Symbols{}` - Hard symbol decisions (Vec<u8>)
  - `%DemodOutput.IQ{}` - Soft I/Q at symbol rate (Vec<{f64, f64}>)

  ## Usage

      case output do
        %DemodOutput.IQ{data: iq, timing_offset: t} ->
          # Defer slicing until constellation is known
          symbols = Slicer.slice_all(iq, constellation)

        %DemodOutput.Symbols{data: symbols} ->
          # Already have hard decisions
          symbols
      end
  """

  defmodule Symbols do
    @moduledoc "Hard symbol decisions from demodulator"
    @enforce_keys [:data]
    defstruct [:data, :timing_offset]

    @type t :: %__MODULE__{
            data: [non_neg_integer()],
            timing_offset: non_neg_integer() | nil
          }
  end

  defmodule IQ do
    @moduledoc "Soft I/Q samples at symbol rate from demodulator"
    @enforce_keys [:data]
    defstruct [:data, :timing_offset]

    @type t :: %__MODULE__{
            data: [{float(), float()}],
            timing_offset: non_neg_integer()
          }
  end

  @type t :: Symbols.t() | IQ.t()

  import Bitwise

  @doc """
  Slice soft I/Q to hard symbols using specified constellation.

  ## Arguments
  - `output` - DemodOutput.IQ struct
  - `constellation` - Atom: :bpsk, :qpsk, :psk8, :qam16, :qam32, :qam64

  ## Returns
  DemodOutput.Symbols struct with hard decisions
  """
  def slice(%IQ{data: iq, timing_offset: t}, constellation) do
    symbols = Enum.map(iq, fn {i, q} -> slice_iq(i, q, constellation) end)
    %Symbols{data: symbols, timing_offset: t}
  end

  def slice(%Symbols{} = s, _constellation), do: s

  # Per-constellation slicing
  defp slice_iq(i, _q, :bpsk) do
    if i >= 0, do: 0, else: 1
  end

  defp slice_iq(i, q, :qpsk) do
    # Gray coded: 00=0°, 01=90°, 11=180°, 10=270°
    case {i >= 0, q >= 0} do
      {true, true} -> 0   # Q1: 0°
      {false, true} -> 1  # Q2: 90°
      {false, false} -> 3 # Q3: 180° (Gray: 11)
      {true, false} -> 2  # Q4: 270° (Gray: 10)
    end
  end

  defp slice_iq(i, q, :psk8) do
    # 8-PSK: angle quantization
    angle = :math.atan2(q, i)
    angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle
    symbol = round(angle / (:math.pi() / 4))
    rem(symbol, 8)
  end

  defp slice_iq(i, q, :qam16) do
    # 4x4 grid, Gray coded
    i_bits = qam_slice_axis(i, 2)
    q_bits = qam_slice_axis(q, 2)
    (i_bits <<< 2) ||| q_bits
  end

  defp slice_iq(i, q, :qam32) do
    # 32-QAM cross constellation - simplified
    # Full implementation would use proper cross pattern
    i_bits = qam_slice_axis(i, 3)
    q_bits = qam_slice_axis(q, 3)
    sym = (i_bits <<< 3) ||| q_bits
    # Clamp to 0-31
    min(sym, 31)
  end

  defp slice_iq(i, q, :qam64) do
    # 8x8 grid, Gray coded
    i_bits = qam_slice_axis(i, 3)
    q_bits = qam_slice_axis(q, 3)
    (i_bits <<< 3) ||| q_bits
  end

  # Slice one axis of QAM constellation
  # Returns Gray-coded bits (0 to 2^n_bits - 1)
  defp qam_slice_axis(val, n_bits) do
    # Normalize to [-1, 1] range assumed
    # Map to grid index
    levels = 1 <<< n_bits
    # Quantize to nearest level
    idx = round((val + 1.0) / 2.0 * (levels - 1))
    # Clamp
    idx = max(0, min(levels - 1, idx))
    # Gray encode
    gray_encode(idx)
  end

  defp gray_encode(n) do
    bxor(n, n >>> 1)
  end
end
