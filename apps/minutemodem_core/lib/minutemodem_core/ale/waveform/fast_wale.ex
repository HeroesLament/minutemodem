defmodule MinuteModemCore.ALE.Waveform.FastWale do
  @moduledoc """
  Fast WALE waveform encoder/decoder per MIL-STD-188-141D G.5.1.8.

  Fast WALE is designed for benign channels (voice quality or better):
  - 120ms preamble (9 Walsh-modulated di-bits = 288 symbols)
  - BPSK data modulation: 1 bit → 1 symbol (0 or 4)
  - 96-symbol data blocks interleaved with 32-symbol probe sequences

  Effective data rate: ~2400 bps at 2400 baud (minus probe overhead)

  Frame structure:
  [TLC (optional)] [Capture Probe (async)] [Preamble] [K] [U:96] [K] [U:96]...

  Where K = known probe (32 symbols), U = unknown data (96 symbols)
  """

  import Bitwise

  alias MinuteModemCore.ALE.Waveform.{Walsh, Scrambler}
  alias MinuteModemCore.ALE.Encoding

  # Symbol rate
  @symbol_rate 2400

  # TLC block (same as Deep WALE)
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

  # Fixed preamble di-bits for Fast WALE (G.5.1.8.2)
  # First 5 use normal set
  @fixed_dibits [3, 3, 1, 2, 0]

  # Probe sequence (G.5.1.8.3.1) - 16 symbols, sent twice = 32
  @probe_base [0, 0, 0, 0, 0, 2, 4, 6, 0, 4, 0, 4, 0, 6, 4, 2]

  def probe_sequence, do: @probe_base ++ @probe_base

  # ===========================================================================
  # Frame Assembly
  # ===========================================================================

  @doc """
  Assemble a complete Fast WALE frame.

  ## Options
  - `:tuner_time_ms` - TLC duration for radio tuning (default: 0)
  - `:capture_probe_count` - Number of capture probes for async (default: 1)
  - `:async` - true for async call (includes capture probe)
  - `:more_pdus` - true if M bit should be set

  Returns list of 8-PSK symbols (0-7).
  """
  def assemble_frame(pdu_binary, opts \\ []) do
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)
    capture_probe_count = Keyword.get(opts, :capture_probe_count, 1)
    async = Keyword.get(opts, :async, true)
    more_pdus = Keyword.get(opts, :more_pdus, false)

    # 1. TLC blocks
    tlc_symbols = build_tlc(tuner_time_ms)

    # 2. Capture probe (async only)
    capture_symbols = if async do
      Walsh.capture_probe()
      |> List.duplicate(capture_probe_count)
      |> List.flatten()
    else
      []
    end

    # 3. Preamble
    preamble_symbols = build_preamble(more_pdus)

    # 4. Initial probe (K)
    initial_probe = probe_sequence()

    # 5. Data blocks with interleaved probes
    data_symbols = encode_data(pdu_binary)

    tlc_symbols ++ capture_symbols ++ preamble_symbols ++ initial_probe ++ data_symbols
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
  # Preamble (G.5.1.8.2)
  # ===========================================================================

  defp build_preamble(more_pdus) do
    # 5 fixed di-bits → normal set Walsh
    fixed_symbols =
      @fixed_dibits
      |> Enum.flat_map(fn dibit ->
        Walsh.walsh_normal(dibit)
        |> Walsh.scramble_preamble()
      end)

    # 4 exceptional di-bits:
    # [0] Waveform ID: 1 = Fast WALE
    # [1] M bit
    # [2] Unused (0)
    # [3] Unused (0)
    waveform_id = 1
    m_bit = if more_pdus, do: 1, else: 0

    exceptional_symbols =
      [waveform_id, m_bit, 0, 0]
      |> Enum.flat_map(fn dibit ->
        Walsh.walsh_exceptional(dibit)
        |> Walsh.scramble_preamble()
      end)

    fixed_symbols ++ exceptional_symbols
  end

  # ===========================================================================
  # Data Encoding (G.5.1.8.3)
  # ===========================================================================

  @doc """
  Encode PDU binary to Fast WALE data symbols.

  Pipeline: PDU → Conv Encode → Interleave → BPSK → Scramble → Insert Probes

  Data is sent in 96-symbol blocks with 32-symbol probes between them.
  """
  def encode_data(pdu_binary) do
    # 1. Convolutional encode (rate 1/2) with flush
    dibits = Encoding.conv_encode_with_flush(pdu_binary)

    # 2. Interleave (12×16 matrix)
    interleaved = Encoding.interleave(dibits, 12, 16)

    # 3. Convert dibits to bits
    bits = dibits_to_bits(interleaved)

    # 4. Map bits to BPSK symbols (0 → 0, 1 → 4)
    bpsk_symbols = Enum.map(bits, fn bit ->
      if bit == 1, do: 4, else: 0
    end)

    # 5. Scramble with 7-bit LFSR (reset at each data frame)
    scrambler = Scrambler.Fast.new()
    {scrambled, _} = Scrambler.Fast.scramble(scrambler, bpsk_symbols)

    # 6. Insert probe sequences every 96 symbols
    insert_probes(scrambled)
  end

  defp dibits_to_bits(dibits) do
    Enum.flat_map(dibits, fn dibit ->
      [(dibit >>> 1) &&& 1, dibit &&& 1]
    end)
  end

  defp insert_probes(symbols) do
    # Split into 96-symbol chunks
    chunks = Enum.chunk_every(symbols, 96)

    # Insert probe after each chunk
    chunks
    |> Enum.flat_map(fn chunk ->
      if length(chunk) == 96 do
        chunk ++ probe_sequence()
      else
        # Last partial chunk - pad and add final probe
        padded = chunk ++ List.duplicate(0, 96 - length(chunk))
        padded ++ probe_sequence()
      end
    end)
  end

  # ===========================================================================
  # Data Decoding
  # ===========================================================================

  @doc """
  Decode Fast WALE data symbols back to bits.

  Pipeline: Remove Probes → Descramble → BPSK → Bits → Dibits
  """
  def decode_data(symbols) do
    # 1. Remove probe sequences (every 128 symbols: 96 data + 32 probe)
    data_only = remove_probes(symbols)

    # 2. Descramble
    scrambler = Scrambler.Fast.new()
    {descrambled, _} = Scrambler.Fast.descramble(scrambler, data_only)

    # 3. BPSK to bits (symbols 0-3 → 0, symbols 4-7 → 1)
    bits = Enum.map(descrambled, fn sym ->
      if sym < 4, do: 0, else: 1
    end)

    # 4. Bits to dibits
    bits_to_dibits(bits)
  end

  defp remove_probes(symbols) do
    # Take 96 data, skip 32 probe, repeat
    symbols
    |> Enum.chunk_every(128)
    |> Enum.flat_map(fn chunk ->
      Enum.take(chunk, 96)
    end)
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
    async = Keyword.get(opts, :async, true)

    tlc_symbols = div(tuner_time_ms * @symbol_rate, 1000)
    capture_symbols = if async, do: 96 * capture_probe_count, else: 0
    preamble_symbols = 288  # 9 di-bits × 32 chips
    initial_probe_symbols = 32

    # Data: PDU → conv encode → interleave → BPSK (1:1) + probes
    pdu_bits = byte_size(pdu_binary) * 8
    # Conv encode: 1 bit → 1 dibit, plus 6 flush dibits
    conv_dibits = pdu_bits + 6
    # Interleave: 12×16 = 192 capacity
    interleaved_dibits = max(conv_dibits, 192)
    # Each dibit = 2 bits, BPSK = 1 symbol per bit
    data_symbols_raw = interleaved_dibits * 2

    # Add probe overhead: one 32-symbol probe per 96 data symbols
    num_data_blocks = div(data_symbols_raw + 95, 96)
    probe_overhead = num_data_blocks * 32
    data_symbols = data_symbols_raw + probe_overhead

    total_symbols = tlc_symbols + capture_symbols + preamble_symbols +
                    initial_probe_symbols + data_symbols
    duration_ms = total_symbols * 1000 / @symbol_rate

    %{
      tlc_symbols: tlc_symbols,
      capture_probe_symbols: capture_symbols,
      preamble_symbols: preamble_symbols,
      initial_probe_symbols: initial_probe_symbols,
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
  def preamble_duration_ms, do: 120

  @doc """
  Symbols per preamble.
  """
  def preamble_symbols, do: 288
end
