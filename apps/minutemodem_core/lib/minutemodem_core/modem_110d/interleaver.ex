defmodule MinuteModemCore.Modem110D.FEC.Interleaver do
  @moduledoc """
  Block interleaver for MIL-STD-188-110D.

  Per D.5.3.3:
  - Single dimension array of size = coded_bits (WID-specific)
  - Load: location[n] = (n * increment) mod size
  - Fetch: linear 0, 1, 2, ...

  ## Example (WID 1, ultra_short, 3 kHz)

  Size = 192 bits, Increment = 25
  - B(0) → location 0
  - B(1) → location 25
  - B(2) → location 50
  - B(7) → location 175
  - B(8) → location 8  (200 mod 192)

  ## Usage

      # With WID struct
      interleaved = Interleaver.interleave(coded_bits, wid)
      deinterleaved = Interleaver.deinterleave(received, wid)

      # With explicit params
      interleaved = Interleaver.interleave(coded_bits, 1, :short, 3)
      deinterleaved = Interleaver.deinterleave(received, 1, :short, 3)
  """

  alias MinuteModemCore.Modem110D.{WID, Waveforms}

  @type interleaver_type :: :ultra_short | :short | :medium | :long

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Interleave coded bits for transmission.

  Per MIL-STD-188-110D D.5.3.3.2:
  - Load bit B(n) at location (n * increment) mod size
  - Fetch linearly from location 0 to size-1

  ## Arguments

  Option 1: `interleave(bits, %WID{})` or `interleave(bits, %WID{}, bw_khz)`
  Option 2: `interleave(bits, waveform, type, bw_khz)`

  ## Returns

  List of interleaved bits
  """
  def interleave(bits, %WID{waveform: wf, interleaver: type}, bw_khz \\ 3) do
    do_interleave(bits, wf, type, bw_khz)
  end

  def interleave(bits, waveform, type, bw_khz) when is_integer(waveform) do
    do_interleave(bits, waveform, type, bw_khz)
  end

  @doc """
  Deinterleave received bits or soft symbols.

  Reverses the interleaving process.

  ## Arguments

  Option 1: `deinterleave(bits, %WID{})` or `deinterleave(bits, %WID{}, bw_khz)`
  Option 2: `deinterleave(bits, waveform, type, bw_khz)`

  ## Returns

  List of deinterleaved bits/symbols
  """
  def deinterleave(bits, %WID{waveform: wf, interleaver: type}, bw_khz \\ 3) do
    do_deinterleave(bits, wf, type, bw_khz)
  end

  def deinterleave(bits, waveform, type, bw_khz) when is_integer(waveform) do
    do_deinterleave(bits, waveform, type, bw_khz)
  end

  @doc """
  Get interleaver block size (coded bits).
  """
  def block_size(%WID{waveform: wf, interleaver: type}, bw_khz \\ 3) do
    Waveforms.coded_bits(wf, type, bw_khz)
  end

  def block_size(waveform, type, bw_khz) when is_integer(waveform) do
    Waveforms.coded_bits(waveform, type, bw_khz)
  end

  @doc """
  Get input data block size (user bits before FEC).
  """
  def input_size(%WID{waveform: wf, interleaver: type}, bw_khz \\ 3) do
    Waveforms.input_bits(wf, type, bw_khz)
  end

  def input_size(waveform, type, bw_khz) when is_integer(waveform) do
    Waveforms.input_bits(waveform, type, bw_khz)
  end

  @doc """
  Get the increment value for a configuration.
  """
  def increment(%WID{waveform: wf, interleaver: type}, bw_khz \\ 3) do
    Waveforms.increment(wf, type, bw_khz)
  end

  def increment(waveform, type, bw_khz) when is_integer(waveform) do
    Waveforms.increment(waveform, type, bw_khz)
  end

  # ===========================================================================
  # Implementation
  # ===========================================================================

  defp do_interleave(bits, waveform, type, bw_khz) when is_list(bits) do
    size = Waveforms.coded_bits(waveform, type, bw_khz)
    inc = Waveforms.increment(waveform, type, bw_khz)

    unless size && inc do
      raise ArgumentError,
        "Invalid interleaver config: waveform=#{waveform}, type=#{type}, bw=#{bw_khz}"
    end

    bits
    |> pad_to_multiple(size)
    |> Enum.chunk_every(size)
    |> Enum.flat_map(&interleave_block(&1, size, inc))
  end

  defp do_deinterleave(bits, waveform, type, bw_khz) when is_list(bits) do
    size = Waveforms.coded_bits(waveform, type, bw_khz)
    inc = Waveforms.increment(waveform, type, bw_khz)

    unless size && inc do
      raise ArgumentError,
        "Invalid interleaver config: waveform=#{waveform}, type=#{type}, bw=#{bw_khz}"
    end

    bits
    |> pad_to_multiple(size)
    |> Enum.chunk_every(size)
    |> Enum.flat_map(&deinterleave_block(&1, size, inc))
  end

  # ===========================================================================
  # Block Operations - Per MIL-STD-188-110D D.5.3.3
  # ===========================================================================

  # Interleave a single block
  # Per D.5.3.3.2: Load at (n * increment) mod size
  # Per D.5.3.3.3: Fetch linearly 0, 1, 2, ...
  defp interleave_block(bits, size, increment) do
    # Create array and load using increment
    array = :array.new(size, default: 0)

    array =
      bits
      |> Enum.with_index()
      |> Enum.reduce(array, fn {bit, n}, arr ->
        loc = rem(n * increment, size)
        :array.set(loc, bit, arr)
      end)

    # Fetch linearly
    for i <- 0..(size - 1), do: :array.get(i, array)
  end

  # Deinterleave a single block
  # Reverse of interleave: read from (n * increment) mod size positions
  defp deinterleave_block(bits, size, increment) do
    input = :array.from_list(bits)

    # For output position n, read from location (n * increment) mod size
    for n <- 0..(size - 1) do
      loc = rem(n * increment, size)
      :array.get(loc, input)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp pad_to_multiple(bits, size) do
    len = length(bits)
    remainder = rem(len, size)

    if remainder == 0 do
      bits
    else
      bits ++ List.duplicate(0, size - remainder)
    end
  end
end
