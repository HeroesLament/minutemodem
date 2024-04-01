defmodule MinuteModemCore.ALE.Waveform.Scrambler do
  @moduledoc """
  WALE data scramblers per MIL-STD-188-141D.

  - Deep WALE: 159-bit shift register, iterated 16× per symbol
  - Fast WALE: 7-bit LFSR (x^7 + x + 1)
  """

  import Bitwise

  # ===========================================================================
  # Deep WALE Scrambler (G.5.1.7.2)
  # ===========================================================================

  defmodule Deep do
    @moduledoc """
    159-bit shift register scrambler for Deep WALE data.

    - Tap at bit 31
    - Iterated 16 times per output symbol
    - Outputs 3-bit value from bits [2,1,0]
    - Initialized per spec at start of each transmission
    """

    import Bitwise

    # Initial state from MIL-STD-188-141D G.5.1.7.2
    @init_state [
      0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 0,
      1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 0, 1,
      0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0,
      0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 1, 1, 1,
      1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 1, 1,
      0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0,
      1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1
    ]

    defstruct [:state]

    def new do
      %__MODULE__{state: @init_state}
    end

    def reset(%__MODULE__{} = _s), do: new()

    @doc """
    Generate next 3-bit scrambling symbol.
    Iterates the LFSR 16 times, outputs bits [2,1,0].
    """
    def next(%__MODULE__{state: state} = scrambler) do
      # Iterate 16 times
      new_state = Enum.reduce(1..16, state, fn _, s ->
        bitout = Enum.at(s, 158)
        bittap = Enum.at(s, 31)
        bitin = bxor(bitout, bittap)
        [bitin | Enum.take(s, 158)]
      end)

      # Output 3-bit value from bits [2,1,0]
      tribit = (Enum.at(new_state, 2) <<< 2) +
               (Enum.at(new_state, 1) <<< 1) +
               Enum.at(new_state, 0)

      {tribit, %{scrambler | state: new_state}}
    end

    @doc """
    Scramble a list of symbols by mod-8 addition.
    """
    def scramble(%__MODULE__{} = scrambler, symbols) do
      {scrambled, final} = Enum.map_reduce(symbols, scrambler, fn sym, scr ->
        {tribit, new_scr} = next(scr)
        {rem(sym + tribit, 8), new_scr}
      end)
      {scrambled, final}
    end

    @doc """
    Descramble symbols (same operation - subtract then mod 8).
    """
    def descramble(%__MODULE__{} = scrambler, symbols) do
      {descrambled, final} = Enum.map_reduce(symbols, scrambler, fn sym, scr ->
        {tribit, new_scr} = next(scr)
        {rem(sym - tribit + 8, 8), new_scr}
      end)
      {descrambled, final}
    end
  end

  # ===========================================================================
  # Fast WALE Scrambler (G.5.1.8.3.2)
  # ===========================================================================

  defmodule Fast do
    @moduledoc """
    7-bit LFSR scrambler for Fast WALE data.

    - Polynomial: x^7 + x + 1
    - Initialized to 1 at start of each data frame
    - Outputs 1 bit per symbol
    """

    import Bitwise

    defstruct [:state]

    def new do
      %__MODULE__{state: 1}
    end

    def reset(%__MODULE__{} = _s), do: new()

    @doc """
    Generate next scrambling bit.
    """
    def next(%__MODULE__{state: state} = scrambler) do
      # Taps at bits 0 and 6
      bit0 = state &&& 1
      bit6 = (state >>> 6) &&& 1
      feedback = bxor(bit0, bit6)

      # Shift right, insert feedback at bit 6
      new_state = ((state >>> 1) ||| (feedback <<< 6)) &&& 0x7F

      {bit0, %{scrambler | state: new_state}}
    end

    @doc """
    Scramble BPSK symbols (0 or 4).
    If scramble bit is 1, flip the symbol (0↔4).
    """
    def scramble(%__MODULE__{} = scrambler, symbols) do
      {scrambled, final} = Enum.map_reduce(symbols, scrambler, fn sym, scr ->
        {bit, new_scr} = next(scr)
        scrambled_sym = if bit == 1, do: rem(sym + 4, 8), else: sym
        {scrambled_sym, new_scr}
      end)
      {scrambled, final}
    end

    @doc """
    Descramble symbols (same operation - XOR is self-inverse).
    """
    def descramble(%__MODULE__{} = scrambler, symbols) do
      scramble(scrambler, symbols)
    end
  end
end
