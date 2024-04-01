defmodule MinuteModemCore.ALE.Waveform.DeepWale do
  @moduledoc """
  Deep WALE waveform encoder/decoder per MIL-STD-188-141D G.5.1.7.

  Deep WALE is designed for challenging HF channels:
  - 240ms preamble (18 Walsh-modulated di-bits = 576 symbols)
  - Walsh-16 data modulation: 4 bits → 64 symbols
  - Only uses symbols 0 and 4 (BPSK for robustness)

  Effective data rate: ~150 bps at 2400 baud

  Frame structure:
  [TLC (optional)] [Capture Probe (async)] [Preamble] [Data]
  """

  import Bitwise

  alias MinuteModemCore.ALE.Waveform.{Walsh, Scrambler}
  alias MinuteModemCore.ALE.Encoding

  # Symbol rate
  @symbol_rate 2400

  # TLC block from spec (256 symbols for AGC settling)
  @tlc_block [
    2, 4, 0, 0, 6, 2, 1, 4, 6, 1, 0, 5, 7, 3, 4, 1,
    2, 6, 1, 7, 0, 7, 3, 2, 2, 2, 3, 2, 4, 6, 3, 6,
    6, 3, 7, 5, 4, 7, 5, 6, 7, 4, 0, 2, 6, 1, 5, 3,
    0, 4, 2, 4, 6, 4, 5, 2, 5, 4, 5, 3, 1, 5, 4, 5,
    6, 5, 1, 0, 7, 1, 0, 1, 0, 5, 3, 5, 2, 2, 4, 5,
    4, 0, 6, 4, 1, 4, 0, 3, 3, 0, 0, 3, 3, 7, 3, 4,
    2, 7, 4, 4, 4, 0, 3, 4, 7, 6, 4, 2, 6, 2, 0, 3,
    5, 3, 2, 2, 4, 5, 2, 0, 0, 3, 5, 0, 3, 2, 6, 6,
    1, 4, 2, 3, 6, 1, 3, 0, 3, 3, 2, 4, 2, 2, 6, 5,
    5, 3, 6, 7, 6, 5, 6, 6, 5, 2, 5, 4, 2, 3, 3, 3,
    5, 7, 5, 5, 3, 7, 0, 4, 7, 0, 4, 1, 6, 2, 3, 5,
    5, 6, 2, 6, 4, 6, 3, 4, 0, 7, 0, 0, 5, 2, 1, 5,
    4, 3, 4, 5, 7, 0, 5, 3, 7, 6, 6, 6, 4, 5, 6, 0,
    2, 0, 4, 2, 3, 4, 4, 0, 7, 6, 6, 2, 0, 0, 3, 3,
    0, 5, 2, 4, 2, 2, 4, 5, 4, 6, 6, 6, 3, 2, 1, 0,
    3, 2, 6, 0, 6, 2, 4, 0, 6, 4, 1, 3, 3, 5, 3, 6
  ]

  # Fixed preamble di-bits (G.5.1.7.1)
  # First 14 use normal set
  @fixed_dibits [0, 1, 2, 1, 0, 0, 2, 3, 1, 3, 3, 1, 2, 0]

  # ===========================================================================
  # Frame Assembly
  # ===========================================================================

  @doc """
  Assemble a complete Deep WALE frame.

  ## Options
  - `:tuner_time_ms` - TLC duration for radio tuning (default: 0, max varies)
  - `:capture_probe_count` - Number of capture probes for async (default: 1)
  - `:preamble_count` - Number of preamble repetitions (default: 1, max: 16)
  - `:async` - true for async call (includes capture probe), false for sync
  - `:more_pdus` - true if M bit should be set (more PDUs follow)

  Returns list of 8-PSK symbols (0-7).
  """
  def assemble_frame(pdu_binary, opts \\ []) do
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)
    capture_probe_count = Keyword.get(opts, :capture_probe_count, 1)
    preamble_count = Keyword.get(opts, :preamble_count, 1) |> min(16)
    async = Keyword.get(opts, :async, true)
    more_pdus = Keyword.get(opts, :more_pdus, false)

    # 1. TLC blocks (tuner adjust time)
    tlc_symbols = build_tlc(tuner_time_ms)

    # 2. Capture probe (async only)
    capture_symbols = if async do
      Walsh.capture_probe()
      |> List.duplicate(capture_probe_count)
      |> List.flatten()
    else
      []
    end

    # 3. Preamble(s)
    preamble_symbols = build_preambles(preamble_count, more_pdus)

    # 4. Data (FEC encoded PDU → Walsh-16 modulated)
    data_symbols = encode_data(pdu_binary)

    tlc_symbols ++ capture_symbols ++ preamble_symbols ++ data_symbols
  end

  @doc """
  Assemble frame for multiple PDUs.
  """
  def assemble_multi_pdu_frame(pdu_binaries, opts \\ []) when is_list(pdu_binaries) do
    opts = Keyword.put(opts, :more_pdus, length(pdu_binaries) > 1)

    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)
    capture_probe_count = Keyword.get(opts, :capture_probe_count, 1)
    preamble_count = Keyword.get(opts, :preamble_count, 1) |> min(16)
    async = Keyword.get(opts, :async, true)
    more_pdus = Keyword.get(opts, :more_pdus, false)

    tlc_symbols = build_tlc(tuner_time_ms)

    capture_symbols = if async do
      Walsh.capture_probe()
      |> List.duplicate(capture_probe_count)
      |> List.flatten()
    else
      []
    end

    preamble_symbols = build_preambles(preamble_count, more_pdus)

    # Encode all PDUs with single scrambler instance
    scrambler = Scrambler.Deep.new()
    {data_symbols, _} = Enum.map_reduce(pdu_binaries, scrambler, fn pdu, scr ->
      encode_data_with_scrambler(pdu, scr)
    end)

    tlc_symbols ++ capture_symbols ++ preamble_symbols ++ List.flatten(data_symbols)
  end

  # ===========================================================================
  # TLC Block
  # ===========================================================================

  defp build_tlc(0), do: []
  defp build_tlc(duration_ms) do
    symbols_needed = div(duration_ms * @symbol_rate, 1000)
    tlc_len = length(@tlc_block)
    reps = div(symbols_needed, tlc_len) + 1

    @tlc_block
    |> List.duplicate(reps)
    |> List.flatten()
    |> Enum.take(symbols_needed)
  end

  # ===========================================================================
  # Preamble (G.5.1.7.1)
  # ===========================================================================

  defp build_preambles(count, more_pdus) do
    for countdown <- (count - 1)..0//-1 do
      build_single_preamble(more_pdus, countdown)
    end
    |> List.flatten()
  end

  defp build_single_preamble(more_pdus, countdown) do
    # 14 fixed di-bits → normal set Walsh (each 32 chips)
    fixed_symbols =
      @fixed_dibits
      |> Enum.flat_map(fn dibit ->
        Walsh.walsh_normal(dibit)
        |> Walsh.scramble_preamble()
      end)

    # 4 exceptional di-bits:
    # [0] Waveform ID: 0 = Deep WALE
    # [1] M bit: 1 if more PDUs, else 0
    # [2] Counter C1: high 2 bits of countdown
    # [3] Counter C0: low 2 bits of countdown
    waveform_id = 0
    m_bit = if more_pdus, do: 1, else: 0
    c1 = (countdown >>> 2) &&& 0x03
    c0 = countdown &&& 0x03

    exceptional_symbols =
      [waveform_id, m_bit, c1, c0]
      |> Enum.flat_map(fn dibit ->
        Walsh.walsh_exceptional(dibit)
        |> Walsh.scramble_preamble()
      end)

    fixed_symbols ++ exceptional_symbols
  end

  # ===========================================================================
  # Data Encoding (G.5.1.7.2)
  # ===========================================================================

  @doc """
  Encode PDU binary to Deep WALE data symbols.

  Pipeline: PDU → Conv Encode → Interleave → Quad-bits → Walsh-16 → Scramble
  """
  def encode_data(pdu_binary) do
    scrambler = Scrambler.Deep.new()
    {symbols, _} = encode_data_with_scrambler(pdu_binary, scrambler)
    symbols
  end

  defp encode_data_with_scrambler(pdu_binary, scrambler) do
    # 1. Convolutional encode (rate 1/2) with flush
    dibits = Encoding.conv_encode_with_flush(pdu_binary)

    # 2. Interleave (12×16 matrix)
    interleaved = Encoding.interleave(dibits, 12, 16)

    # 3. Convert dibits to bits
    bits = dibits_to_bits(interleaved)

    # 4. Group into quad-bits (4 bits each)
    quadbits = bits_to_quadbits(bits)

    # 5. Map each quad-bit to Walsh-16 sequence (64 symbols)
    walsh_symbols = Enum.flat_map(quadbits, &Walsh.walsh_16/1)

    # 6. Scramble with 159-bit LFSR
    Scrambler.Deep.scramble(scrambler, walsh_symbols)
  end

  defp dibits_to_bits(dibits) do
    Enum.flat_map(dibits, fn dibit ->
      [(dibit >>> 1) &&& 1, dibit &&& 1]
    end)
  end

  defp bits_to_quadbits(bits) do
    # Pad to multiple of 4
    padding = rem(4 - rem(length(bits), 4), 4)
    padded = bits ++ List.duplicate(0, padding)

    padded
    |> Enum.chunk_every(4)
    |> Enum.map(fn [b0, b1, b2, b3] ->
      (b0 <<< 3) ||| (b1 <<< 2) ||| (b2 <<< 1) ||| b3
    end)
  end

  # ===========================================================================
  # Data Decoding
  # ===========================================================================

  @doc """
  Decode Deep WALE data symbols back to PDU binary.

  Pipeline: Symbols → Descramble → Walsh correlate → Quad-bits → Bits → Deinterleave → Viterbi
  """
  def decode_data(symbols, scrambler \\ nil) do
    scrambler = scrambler || Scrambler.Deep.new()

    # 1. Descramble
    {descrambled, final_scrambler} = Scrambler.Deep.descramble(scrambler, symbols)

    # 2. Correlate Walsh-16 sequences (64 symbols each) to recover quad-bits
    quadbits =
      descrambled
      |> Enum.chunk_every(64)
      |> Enum.map(fn chunk ->
        if length(chunk) == 64 do
          {quadbit, _score} = Walsh.correlate_walsh_16(chunk)
          quadbit
        else
          0
        end
      end)

    # 3. Convert quad-bits to bits
    bits = Enum.flat_map(quadbits, fn qb ->
      [(qb >>> 3) &&& 1, (qb >>> 2) &&& 1, (qb >>> 1) &&& 1, qb &&& 1]
    end)

    # 4. Convert bits to dibits
    dibits = bits_to_dibits(bits)

    # Return dibits for further processing (deinterleave + Viterbi)
    {dibits, final_scrambler}
  end

  defp bits_to_dibits(bits) do
    bits
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [b1, b0] -> (b1 <<< 1) ||| b0
      [b1] -> b1 <<< 1
    end)
  end

  # ===========================================================================
  # Timing Calculations
  # ===========================================================================

  @doc """
  Calculate frame timing information.
  """
  def frame_timing(pdu_binary, opts \\ []) do
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)
    capture_probe_count = Keyword.get(opts, :capture_probe_count, 1)
    preamble_count = Keyword.get(opts, :preamble_count, 1)
    async = Keyword.get(opts, :async, true)

    tlc_symbols = div(tuner_time_ms * @symbol_rate, 1000)
    capture_symbols = if async, do: 96 * capture_probe_count, else: 0
    preamble_symbols = 576 * preamble_count  # 18 di-bits × 32 chips

    # Data: PDU → conv encode → interleave → quad-bits → Walsh-16
    pdu_bits = byte_size(pdu_binary) * 8
    # Conv encode: rate 1/2 means 1 bit in → 1 dibit out, plus K-1=6 flush dibits
    conv_dibits = pdu_bits + 6
    # Interleave: 12×16 = 192 capacity
    interleaved_dibits = max(conv_dibits, 192)  # Padded to matrix size
    # Each dibit = 2 bits, group into quadbits (4 bits)
    total_bits = interleaved_dibits * 2
    quadbits = div(total_bits + 3, 4)
    data_symbols = quadbits * 64

    total_symbols = tlc_symbols + capture_symbols + preamble_symbols + data_symbols
    duration_ms = total_symbols * 1000 / @symbol_rate

    %{
      tlc_symbols: tlc_symbols,
      capture_probe_symbols: capture_symbols,
      preamble_symbols: preamble_symbols,
      data_symbols: data_symbols,
      total_symbols: total_symbols,
      duration_ms: duration_ms,
      # Component durations
      tlc_ms: tuner_time_ms,
      capture_probe_ms: capture_symbols * 1000 / @symbol_rate,
      preamble_ms: preamble_symbols * 1000 / @symbol_rate,
      data_ms: data_symbols * 1000 / @symbol_rate
    }
  end

  @doc """
  Preamble duration in ms.
  """
  def preamble_duration_ms, do: 240

  @doc """
  Symbols per preamble.
  """
  def preamble_symbols, do: 576
end
