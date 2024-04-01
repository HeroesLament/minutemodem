defmodule MinuteModemCore.ALE.Waveform.Walsh do
  @moduledoc """
  Walsh orthogonal modulation for WALE preambles and data.

  Implements MIL-STD-188-141D Appendix G Tables G-VII, G-VIII, and G-IX.

  Key insight: WALE uses only symbols 0 and 4 (0° and 180°) for data,
  which is effectively BPSK carried on an 8-PSK constellation.
  """

  # ===========================================================================
  # Table G-VII: Capture Probe Sequence (96 symbols)
  # ===========================================================================

  # This is the known sequence scanning receivers look for at the start
  # of asynchronous calls. Only uses symbols 0 and 4.
  @capture_probe [
    0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 4, 0, 0, 4,
    4, 4, 0, 4, 0, 0, 0, 4, 0, 4, 0, 4, 4, 0, 4, 0,
    0, 0, 0, 4, 4, 4, 4, 0, 0, 4, 0, 4, 0, 4, 4, 4,
    0, 4, 4, 0, 0, 0, 4, 0, 4, 4, 4, 0, 4, 0, 0, 4,
    4, 0, 4, 4, 0, 4, 0, 4, 0, 0, 0, 4, 4, 0, 0, 4,
    0, 4, 0, 0, 4, 4, 0, 4, 4, 0, 4, 0, 4, 4, 0, 0
  ]

  def capture_probe, do: @capture_probe
  def capture_probe_length, do: 96

  # ===========================================================================
  # Table G-VIII: Walsh Sequences for WALE Preambles
  # ===========================================================================

  # Normal set: 4-element base, repeated 8× = 32 chips
  @walsh_normal_4 %{
    0 => [0, 0, 0, 0],
    1 => [0, 4, 0, 4],
    2 => [0, 0, 4, 4],
    3 => [0, 4, 4, 0]
  }

  def walsh_normal(dibit) when dibit in 0..3 do
    @walsh_normal_4[dibit]
    |> List.duplicate(8)
    |> List.flatten()
  end

  # Exceptional set: 8-element base, repeated 4× = 32 chips
  @walsh_exceptional_8 %{
    0 => [0, 0, 0, 0, 4, 4, 4, 4],
    1 => [0, 4, 0, 4, 4, 0, 4, 0],
    2 => [0, 0, 4, 4, 4, 4, 0, 0],
    3 => [0, 4, 4, 0, 4, 0, 0, 4]
  }

  def walsh_exceptional(dibit) when dibit in 0..3 do
    @walsh_exceptional_8[dibit]
    |> List.duplicate(4)
    |> List.flatten()
  end

  # ===========================================================================
  # Preamble Scrambling (G.5.1.6)
  # ===========================================================================

  @preamble_scramble [
    7, 1, 1, 3, 7, 3, 1, 5, 5, 1, 1, 6, 7, 1, 5, 4,
    1, 7, 1, 6, 3, 6, 1, 0, 4, 1, 0, 7, 5, 5, 2, 6
  ]

  def scramble_preamble(chips) when length(chips) == 32 do
    Enum.zip(chips, @preamble_scramble)
    |> Enum.map(fn {chip, scr} -> rem(chip + scr, 8) end)
  end

  def descramble_preamble(chips) when length(chips) == 32 do
    Enum.zip(chips, @preamble_scramble)
    |> Enum.map(fn {chip, scr} -> rem(chip - scr + 8, 8) end)
  end

  # ===========================================================================
  # Table G-IX: Walsh-16 Sequences for Deep WALE Data
  # ===========================================================================

  # Each quad-bit maps to 16 symbols, repeated 4× = 64 symbols
  @walsh_16 %{
    0b0000 => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    0b0001 => [0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4],
    0b0010 => [0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4],
    0b0011 => [0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0, 0, 4, 4, 0],
    0b0100 => [0, 0, 0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4],
    0b0101 => [0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0],
    0b0110 => [0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4, 0, 0],
    0b0111 => [0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4],
    0b1000 => [0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4],
    0b1001 => [0, 4, 0, 4, 0, 4, 0, 4, 4, 0, 4, 0, 4, 0, 4, 0],
    0b1010 => [0, 0, 4, 4, 0, 0, 4, 4, 4, 4, 0, 0, 4, 4, 0, 0],
    0b1011 => [0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4],
    0b1100 => [0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, 0, 0, 0, 0],
    0b1101 => [0, 4, 0, 4, 4, 0, 4, 0, 4, 0, 4, 0, 0, 4, 0, 4],
    0b1110 => [0, 0, 4, 4, 4, 4, 0, 0, 4, 4, 0, 0, 0, 0, 4, 4],
    0b1111 => [0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0]
  }

  def walsh_16(quadbit) when quadbit in 0..15 do
    @walsh_16[quadbit]
    |> List.duplicate(4)
    |> List.flatten()
  end

  def walsh_16_base(quadbit) when quadbit in 0..15 do
    @walsh_16[quadbit]
  end

  # ===========================================================================
  # Correlation / Demodulation
  # ===========================================================================

  def correlate_normal(chips) when length(chips) == 32 do
    descrambled = descramble_preamble(chips)

    0..3
    |> Enum.map(fn dibit ->
      ref = walsh_normal(dibit)
      {dibit, correlate_bpsk(descrambled, ref)}
    end)
    |> Enum.max_by(fn {_, score} -> score end)
  end

  def correlate_exceptional(chips) when length(chips) == 32 do
    descrambled = descramble_preamble(chips)

    0..3
    |> Enum.map(fn dibit ->
      ref = walsh_exceptional(dibit)
      {dibit, correlate_bpsk(descrambled, ref)}
    end)
    |> Enum.max_by(fn {_, score} -> score end)
  end

  def correlate_walsh_16(symbols) when length(symbols) == 64 do
    0..15
    |> Enum.map(fn quadbit ->
      ref = walsh_16(quadbit)
      {quadbit, correlate_bpsk(symbols, ref)}
    end)
    |> Enum.max_by(fn {_, score} -> score end)
  end

  # BPSK correlation: 0-3 → +1, 4-7 → -1
  defp correlate_bpsk(received, reference) do
    Enum.zip(received, reference)
    |> Enum.reduce(0, fn {r, ref}, acc ->
      r_sign = if r < 4, do: 1, else: -1
      ref_sign = if ref < 4, do: 1, else: -1
      acc + r_sign * ref_sign
    end)
  end
end
