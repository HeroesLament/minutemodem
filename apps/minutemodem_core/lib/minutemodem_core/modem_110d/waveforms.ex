defmodule MinuteModemCore.Modem110D.Waveforms do
  @moduledoc """
  MIL-STD-188-110D Waveform Parameters.

  Canonical tables from the specification:
  - TABLE D-LI: Interleaver increment values (3 kHz)
  - Interleaver block parameters (frames, coded bits, input bits)
  - Code rates and modulation per waveform

  All parameters indexed by:
  - `wid` - Waveform ID (0-13)
  - `interleaver` - Interleaver type (:ultra_short, :short, :medium, :long)
  - `bw_khz` - Bandwidth in kHz (3, 6, 9, 12, etc.)
  """

  @type wid :: 0..13
  @type interleaver :: :ultra_short | :short | :medium | :long
  @type bandwidth :: 3 | 6 | 9 | 12 | 15 | 18 | 21 | 24

  # ===========================================================================
  # TABLE D-LI: Interleaver increment values (3 kHz bandwidth)
  # ===========================================================================

  @increments_3khz %{
    # WID 0 - Walsh (no ultra_short)
    {0, :short} => 11,
    {0, :medium} => 37,
    {0, :long} => 145,
    # WID 1
    {1, :ultra_short} => 25,
    {1, :short} => 97,
    {1, :medium} => 385,
    {1, :long} => 1543,
    # WID 2
    {2, :ultra_short} => 25,
    {2, :short} => 97,
    {2, :medium} => 385,
    {2, :long} => 1543,
    # WID 3
    {3, :ultra_short} => 25,
    {3, :short} => 97,
    {3, :medium} => 385,
    {3, :long} => 1549,
    # WID 4
    {4, :ultra_short} => 25,
    {4, :short} => 97,
    {4, :medium} => 385,
    {4, :long} => 1549,
    # WID 5
    {5, :ultra_short} => 33,
    {5, :short} => 129,
    {5, :medium} => 513,
    {5, :long} => 2081,
    # WID 6
    {6, :ultra_short} => 65,
    {6, :short} => 257,
    {6, :medium} => 1025,
    {6, :long} => 4161,
    # WID 7
    {7, :ultra_short} => 97,
    {7, :short} => 385,
    {7, :medium} => 1537,
    {7, :long} => 6241,
    # WID 8
    {8, :ultra_short} => 129,
    {8, :short} => 641,
    {8, :medium} => 2049,
    {8, :long} => 8321,
    # WID 9
    {9, :ultra_short} => 161,
    {9, :short} => 641,
    {9, :medium} => 2561,
    {9, :long} => 10403,
    # WID 10
    {10, :ultra_short} => 193,
    {10, :short} => 769,
    {10, :medium} => 3073,
    {10, :long} => 12481,
    # WID 11
    {11, :ultra_short} => 271,
    {11, :short} => 1081,
    {11, :medium} => 4321,
    {11, :long} => 17551,
    # WID 12
    {12, :ultra_short} => 361,
    {12, :short} => 1441,
    {12, :medium} => 5761,
    {12, :long} => 23401,
    # WID 13
    {13, :ultra_short} => 65,
    {13, :short} => 257,
    {13, :medium} => 1025,
    {13, :long} => 4161
  }

  # ===========================================================================
  # Interleaver block parameters (3 kHz bandwidth)
  # {frames, coded_bits, input_bits}
  # ===========================================================================

  @block_params_3khz %{
    # WID 0 - Walsh (no ultra_short, special case)
    {0, :short} => {40, 80, 40},
    {0, :medium} => {144, 288, 144},
    {0, :long} => {576, 1152, 576},
    # WID 1 - 75 bps, BPSK, rate 1/8
    {1, :ultra_short} => {4, 192, 24},
    {1, :short} => {16, 768, 96},
    {1, :medium} => {64, 3072, 384},
    {1, :long} => {256, 12288, 1536},
    # WID 2 - 150 bps, BPSK, rate 1/4
    {2, :ultra_short} => {4, 192, 48},
    {2, :short} => {16, 768, 192},
    {2, :medium} => {64, 3072, 768},
    {2, :long} => {256, 12288, 3072},
    # WID 3 - 300 bps, BPSK, rate 1/2
    {3, :ultra_short} => {2, 192, 64},
    {3, :short} => {8, 768, 256},
    {3, :medium} => {32, 3072, 1024},
    {3, :long} => {128, 12288, 4096},
    # WID 4 - 600 bps, QPSK, rate 1/2
    {4, :ultra_short} => {2, 192, 128},
    {4, :short} => {8, 768, 512},
    {4, :medium} => {32, 3072, 2048},
    {4, :long} => {128, 12288, 8192},
    # WID 5 - 1200 bps, 8PSK, rate 1/2
    {5, :ultra_short} => {1, 256, 192},
    {5, :short} => {4, 1024, 768},
    {5, :medium} => {16, 4096, 3072},
    {5, :long} => {64, 16384, 12288},
    # WID 6 - 2400 bps, 16QAM, rate 1/2
    {6, :ultra_short} => {1, 512, 384},
    {6, :short} => {4, 2048, 1536},
    {6, :medium} => {16, 8192, 6144},
    {6, :long} => {64, 32768, 24576},
    # WID 7 - 3600 bps, 16QAM, rate 3/4
    {7, :ultra_short} => {1, 768, 576},
    {7, :short} => {4, 3072, 2304},
    {7, :medium} => {16, 12288, 9216},
    {7, :long} => {64, 49152, 36864},
    # WID 8 - 4800 bps, 32QAM, rate 3/4
    {8, :ultra_short} => {1, 1024, 768},
    {8, :short} => {4, 4096, 3072},
    {8, :medium} => {16, 16384, 12288},
    {8, :long} => {64, 65536, 49152},
    # WID 9 - 6000 bps, 32QAM, rate 15/16
    {9, :ultra_short} => {1, 1280, 960},
    {9, :short} => {4, 5120, 3840},
    {9, :medium} => {16, 20480, 15360},
    {9, :long} => {64, 81920, 61440},
    # WID 10 - 7200 bps, 64QAM, rate 3/4
    {10, :ultra_short} => {1, 1536, 1152},
    {10, :short} => {4, 6144, 4608},
    {10, :medium} => {16, 24576, 18432},
    {10, :long} => {64, 98304, 73728},
    # WID 11 - 9600 bps, 64QAM (uncoded)
    {11, :ultra_short} => {1, 2160, 1920},
    {11, :short} => {4, 8640, 7680},
    {11, :medium} => {16, 34560, 30720},
    {11, :long} => {64, 138240, 122880},
    # WID 12 - 12800 bps, 64QAM (uncoded)
    {12, :ultra_short} => {1, 2880, 2560},
    {12, :short} => {4, 11520, 10240},
    {12, :medium} => {16, 46080, 40960},
    {12, :long} => {64, 184320, 163840},
    # WID 13 - 1200 bps robust, 8PSK
    {13, :ultra_short} => {1, 512, 288},
    {13, :short} => {4, 2048, 1152},
    {13, :medium} => {16, 8192, 4608},
    {13, :long} => {64, 32768, 18432}
  }

  # ===========================================================================
  # Code rates per waveform (TABLE D-XLIX)
  # ===========================================================================

  @code_rates %{
    0 => :walsh,
    1 => {1, 8},
    2 => {1, 4},
    3 => {1, 2},
    4 => {1, 2},
    5 => {1, 2},
    6 => {1, 2},
    7 => {3, 4},
    8 => {3, 4},
    9 => {15, 16},
    10 => {3, 4},
    11 => :uncoded,
    12 => :uncoded,
    13 => {9, 16}
  }

  # ===========================================================================
  # Modulation per waveform
  # ===========================================================================

  @modulation %{
    0 => :walsh,
    1 => :bpsk,
    2 => :bpsk,
    3 => :bpsk,
    4 => :qpsk,
    5 => :psk8,
    6 => :qam16,
    7 => :qam16,
    8 => :qam32,
    9 => :qam32,
    10 => :qam64,
    11 => :qam64,
    12 => :qam64,
    13 => :psk8
  }

  # ===========================================================================
  # Data rates per waveform (bps at 3 kHz bandwidth)
  # ===========================================================================

  @data_rates_3khz %{
    0 => 0,
    1 => 75,
    2 => 150,
    3 => 300,
    4 => 600,
    5 => 1200,
    6 => 2400,
    7 => 3600,
    8 => 4800,
    9 => 6000,
    10 => 7200,
    11 => 9600,
    12 => 12800,
    13 => 1200
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Get the interleaver increment value.

  Per MIL-STD-188-110D D.5.3.3.2:
  Load Location = (n * increment) mod size
  """
  @spec increment(wid, interleaver, bandwidth) :: pos_integer | nil
  def increment(wid, interleaver, bw_khz \\ 3)

  def increment(wid, interleaver, 3) do
    Map.get(@increments_3khz, {wid, interleaver})
  end

  def increment(wid, interleaver, bw_khz) when bw_khz > 3 do
    # For wider bandwidths, scale the increment
    base = Map.get(@increments_3khz, {wid, interleaver})
    if base, do: base * div(bw_khz, 3), else: nil
  end

  @doc """
  Get the number of frames in an interleaver block.
  """
  @spec frames(wid, interleaver, bandwidth) :: pos_integer | nil
  def frames(wid, interleaver, bw_khz \\ 3)

  def frames(wid, interleaver, 3) do
    case Map.get(@block_params_3khz, {wid, interleaver}) do
      {f, _c, _i} -> f
      nil -> nil
    end
  end

  def frames(wid, interleaver, bw_khz) when bw_khz > 3 do
    base = frames(wid, interleaver, 3)
    if base, do: base * div(bw_khz, 3), else: nil
  end

  @doc """
  Get the number of coded bits (interleaver size) per block.
  """
  @spec coded_bits(wid, interleaver, bandwidth) :: pos_integer | nil
  def coded_bits(wid, interleaver, bw_khz \\ 3)

  def coded_bits(wid, interleaver, 3) do
    case Map.get(@block_params_3khz, {wid, interleaver}) do
      {_f, c, _i} -> c
      nil -> nil
    end
  end

  def coded_bits(wid, interleaver, bw_khz) when bw_khz > 3 do
    base = coded_bits(wid, interleaver, 3)
    if base, do: base * div(bw_khz, 3), else: nil
  end

  @doc """
  Get the number of input (user data) bits per interleaver block.
  """
  @spec input_bits(wid, interleaver, bandwidth) :: pos_integer | nil
  def input_bits(wid, interleaver, bw_khz \\ 3)

  def input_bits(wid, interleaver, 3) do
    case Map.get(@block_params_3khz, {wid, interleaver}) do
      {_f, _c, i} -> i
      nil -> nil
    end
  end

  def input_bits(wid, interleaver, bw_khz) when bw_khz > 3 do
    base = input_bits(wid, interleaver, 3)
    if base, do: base * div(bw_khz, 3), else: nil
  end

  @doc """
  Get the number of input (user data) bytes per interleaver block.
  """
  @spec input_bytes(wid, interleaver, bandwidth) :: pos_integer | nil
  def input_bytes(wid, interleaver, bw_khz \\ 3) do
    case input_bits(wid, interleaver, bw_khz) do
      nil -> nil
      bits -> div(bits, 8)
    end
  end

  @doc """
  Get the code rate for a waveform.

  Returns:
  - `{numerator, denominator}` for coded waveforms
  - `:walsh` for WID 0
  - `:uncoded` for WIDs 11-12
  """
  @spec code_rate(wid) :: {pos_integer, pos_integer} | :walsh | :uncoded
  def code_rate(wid), do: Map.fetch!(@code_rates, wid)

  @doc """
  Get the modulation type for a waveform.
  """
  @spec modulation(wid) :: atom
  def modulation(wid), do: Map.fetch!(@modulation, wid)

  @doc """
  Get the data rate in bps for a waveform at a given bandwidth.
  """
  @spec data_rate(wid, bandwidth) :: non_neg_integer
  def data_rate(wid, bw_khz \\ 3) do
    base = Map.fetch!(@data_rates_3khz, wid)
    base * div(bw_khz, 3)
  end

  @doc """
  Get bits per symbol for a waveform.
  """
  @spec bits_per_symbol(wid) :: pos_integer
  def bits_per_symbol(wid) do
    case modulation(wid) do
      :walsh -> 1
      :bpsk -> 1
      :qpsk -> 2
      :psk8 -> 3
      :qam16 -> 4
      :qam32 -> 5
      :qam64 -> 6
    end
  end

  @doc """
  Check if a waveform/interleaver combination is valid.
  """
  @spec valid?(wid, interleaver, bandwidth) :: boolean
  def valid?(wid, interleaver, bw_khz \\ 3) do
    increment(wid, interleaver, bw_khz) != nil
  end

  @doc """
  List all valid interleaver types for a waveform.
  """
  @spec valid_interleavers(wid) :: [interleaver]
  def valid_interleavers(wid) do
    [:ultra_short, :short, :medium, :long]
    |> Enum.filter(&valid?(wid, &1, 3))
  end

  @doc """
  Get all parameters for a waveform/interleaver combo as a map.
  """
  @spec params(wid, interleaver, bandwidth) :: map | nil
  def params(wid, interleaver, bw_khz \\ 3) do
    if valid?(wid, interleaver, bw_khz) do
      %{
        wid: wid,
        interleaver: interleaver,
        bandwidth_khz: bw_khz,
        increment: increment(wid, interleaver, bw_khz),
        frames: frames(wid, interleaver, bw_khz),
        coded_bits: coded_bits(wid, interleaver, bw_khz),
        input_bits: input_bits(wid, interleaver, bw_khz),
        input_bytes: input_bytes(wid, interleaver, bw_khz),
        code_rate: code_rate(wid),
        modulation: modulation(wid),
        data_rate_bps: data_rate(wid, bw_khz),
        bits_per_symbol: bits_per_symbol(wid)
      }
    end
  end
end
