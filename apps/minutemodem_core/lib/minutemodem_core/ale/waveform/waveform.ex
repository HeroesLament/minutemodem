defmodule MinuteModemCore.ALE.Waveform do
  @moduledoc """
  MIL-STD-188-141D WALE (Waveform for ALE) unified interface.

  Provides a single API for both Deep WALE and Fast WALE waveforms,
  with configurable parameters for:
  - Tuner adjust time (TLC blocks)
  - Capture probe repetitions
  - Preamble repetitions (Deep only)
  - Waveform selection

  ## Waveform Comparison

  | Feature | Deep WALE | Fast WALE |
  |---------|-----------|-----------|
  | Preamble | 240ms | 120ms |
  | Data Rate | ~150 bps | ~2400 bps |
  | Channel | Challenging | Benign |
  | Modulation | Walsh-16 | BPSK |
  | Spreading | 64 symbols/4 bits | 1 symbol/bit |

  ## Usage

      # Assemble an async call frame with Deep WALE
      symbols = Waveform.assemble_frame(pdu_binary,
        waveform: :deep,
        async: true,
        tuner_time_ms: 40,
        capture_probe_count: 2
      )

      # Get timing information
      timing = Waveform.frame_timing(pdu_binary, waveform: :fast)
  """

  alias MinuteModemCore.ALE.Waveform.{DeepWale, FastWale, Walsh}

  @type waveform :: :deep | :fast

  @type frame_opts :: [
    waveform: waveform(),
    async: boolean(),
    tuner_time_ms: non_neg_integer(),
    capture_probe_count: pos_integer(),
    preamble_count: pos_integer(),
    more_pdus: boolean()
  ]

  # ===========================================================================
  # Frame Assembly
  # ===========================================================================

  @doc """
  Assemble a complete WALE frame from a PDU binary.

  ## Options
  - `:waveform` - `:deep` or `:fast` (default: `:deep`)
  - `:async` - true for async call with capture probe (default: true)
  - `:tuner_time_ms` - TLC duration for radio tuning (default: 0)
  - `:capture_probe_count` - Number of capture probe repetitions (default: 1)
  - `:preamble_count` - Preamble repetitions, Deep only (default: 1)
  - `:more_pdus` - Set M bit if more PDUs follow (default: false)

  Returns list of 8-PSK symbols (0-7) ready for modulation.
  """
  @spec assemble_frame(binary(), frame_opts()) :: [0..7]
  def assemble_frame(pdu_binary, opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :deep)

    case waveform do
      :deep -> DeepWale.assemble_frame(pdu_binary, opts)
      :fast -> FastWale.assemble_frame(pdu_binary, opts)
    end
  end

  @doc """
  Assemble a frame containing multiple PDUs.
  """
  @spec assemble_multi_pdu_frame([binary()], frame_opts()) :: [0..7]
  def assemble_multi_pdu_frame(pdu_binaries, opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :deep)

    case waveform do
      :deep -> DeepWale.assemble_multi_pdu_frame(pdu_binaries, opts)
      :fast ->
        # Fast WALE: concatenate individual frames
        # (M bit handling would go here for proper multi-PDU)
        Enum.flat_map(pdu_binaries, fn pdu ->
          FastWale.assemble_frame(pdu, opts)
        end)
    end
  end

  # ===========================================================================
  # Timing
  # ===========================================================================

  @doc """
  Calculate frame timing information.

  Returns a map with symbol counts and durations for each component.
  """
  @spec frame_timing(binary(), frame_opts()) :: map()
  def frame_timing(pdu_binary, opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :deep)

    case waveform do
      :deep -> DeepWale.frame_timing(pdu_binary, opts)
      :fast -> FastWale.frame_timing(pdu_binary, opts)
    end
  end

  @doc """
  Get preamble duration in milliseconds.
  """
  @spec preamble_duration_ms(waveform()) :: number()
  def preamble_duration_ms(:deep), do: DeepWale.preamble_duration_ms()
  def preamble_duration_ms(:fast), do: FastWale.preamble_duration_ms()

  @doc """
  Get capture probe sequence.
  """
  @spec capture_probe() :: [0..7]
  def capture_probe, do: Walsh.capture_probe()

  @doc """
  Get capture probe length in symbols.
  """
  @spec capture_probe_length() :: pos_integer()
  def capture_probe_length, do: Walsh.capture_probe_length()

  # ===========================================================================
  # Detection / Decoding
  # ===========================================================================

  @doc """
  Detect waveform type from received preamble symbols.

  Returns {:ok, :deep | :fast, preamble_info} or {:error, reason}.
  """
  @spec detect_waveform([0..7]) :: {:ok, waveform(), map()} | {:error, atom()}
  def detect_waveform(symbols) do
    # Need at least 9 Walsh blocks (288 symbols) for Fast WALE
    # or 18 Walsh blocks (576 symbols) for Deep WALE
    cond do
      length(symbols) >= 576 ->
        # Try Deep WALE first (has distinctive fixed pattern)
        case detect_deep_preamble(symbols) do
          {:ok, info} -> {:ok, :deep, info}
          _ ->
            # Try Fast WALE
            case detect_fast_preamble(symbols) do
              {:ok, info} -> {:ok, :fast, info}
              error -> error
            end
        end

      length(symbols) >= 288 ->
        detect_fast_preamble(symbols)
        |> case do
          {:ok, info} -> {:ok, :fast, info}
          error -> error
        end

      true ->
        {:error, :insufficient_symbols}
    end
  end

  defp detect_deep_preamble(symbols) do
    # Deep WALE: 14 fixed normal + 4 exceptional = 18 × 32 = 576 symbols
    fixed_dibits = [0, 1, 2, 1, 0, 0, 2, 3, 1, 3, 3, 1, 2, 0]

    # Decode first 14 Walsh blocks
    decoded =
      symbols
      |> Enum.take(14 * 32)
      |> Enum.chunk_every(32)
      |> Enum.map(fn chunk ->
        {dibit, score} = Walsh.correlate_normal(chunk)
        {dibit, score}
      end)

    decoded_dibits = Enum.map(decoded, fn {d, _} -> d end)
    avg_score = decoded |> Enum.map(fn {_, s} -> s end) |> Enum.sum() |> div(14)

    if decoded_dibits == fixed_dibits and avg_score > 20 do
      # Decode exceptional di-bits
      exceptional = symbols
        |> Enum.slice(14 * 32, 4 * 32)
        |> Enum.chunk_every(32)
        |> Enum.map(fn chunk ->
          {dibit, _} = Walsh.correlate_exceptional(chunk)
          dibit
        end)

      [waveform_id, m_bit, c1, c0] = exceptional

      if waveform_id == 0 do
        {:ok, %{
          waveform: :deep,
          more_pdus: m_bit == 1,
          preamble_count: Bitwise.bor(Bitwise.bsl(c1, 2), c0),
          correlation_score: avg_score
        }}
      else
        {:error, :wrong_waveform_id}
      end
    else
      {:error, :pattern_mismatch}
    end
  end

  defp detect_fast_preamble(symbols) do
    # Fast WALE: 5 fixed normal + 4 exceptional = 9 × 32 = 288 symbols
    fixed_dibits = [3, 3, 1, 2, 0]

    decoded =
      symbols
      |> Enum.take(5 * 32)
      |> Enum.chunk_every(32)
      |> Enum.map(fn chunk ->
        {dibit, score} = Walsh.correlate_normal(chunk)
        {dibit, score}
      end)

    decoded_dibits = Enum.map(decoded, fn {d, _} -> d end)
    avg_score = decoded |> Enum.map(fn {_, s} -> s end) |> Enum.sum() |> div(5)

    if decoded_dibits == fixed_dibits and avg_score > 20 do
      exceptional = symbols
        |> Enum.slice(5 * 32, 4 * 32)
        |> Enum.chunk_every(32)
        |> Enum.map(fn chunk ->
          {dibit, _} = Walsh.correlate_exceptional(chunk)
          dibit
        end)

      [waveform_id, m_bit, _, _] = exceptional

      if waveform_id == 1 do
        {:ok, %{
          waveform: :fast,
          more_pdus: m_bit == 1,
          correlation_score: avg_score
        }}
      else
        {:error, :wrong_waveform_id}
      end
    else
      {:error, :pattern_mismatch}
    end
  end

  @doc """
  Decode data symbols based on waveform type.
  """
  @spec decode_data(waveform(), [0..7]) :: {:ok, [0..3]} | {:error, atom()}
  def decode_data(:deep, symbols) do
    {dibits, _scrambler} = DeepWale.decode_data(symbols)
    {:ok, dibits}
  end

  def decode_data(:fast, symbols) do
    dibits = FastWale.decode_data(symbols)
    {:ok, dibits}
  end

  # ===========================================================================
  # Constants
  # ===========================================================================

  @doc """
  Symbol rate for WALE (both Deep and Fast).
  """
  @spec symbol_rate() :: pos_integer()
  def symbol_rate, do: 2400

  @doc """
  Symbols per TLC block.
  """
  @spec tlc_block_symbols() :: pos_integer()
  def tlc_block_symbols, do: 256

  @doc """
  TLC block duration in milliseconds.
  """
  @spec tlc_block_duration_ms() :: number()
  def tlc_block_duration_ms, do: 256 / 2400 * 1000  # ~106.7ms
end
