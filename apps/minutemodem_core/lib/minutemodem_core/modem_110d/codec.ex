defmodule MinuteModemCore.Modem110D.Codec do
  @moduledoc """
  High-level codec for MIL-STD-188-110D data transmission.

  Wraps the complete TX and RX chains including:
  - FEC encoding/decoding (convolutional + Viterbi)
  - Interleaving/deinterleaving
  - Puncturing/depuncturing
  - Symbol mapping/demapping
  - EOM handling

  ## TX Flow

      data_bits
          │
          ▼
      [Optional EOM append]
          │
          ▼
      Convolutional Encode (K=7 or K=9)
          │
          ▼
      Puncture (rate 1/2, 3/4, or 7/8)
          │
          ▼
      Interleave
          │
          ▼
      Symbol Map (BPSK, QPSK, 8-PSK, 16-QAM, etc.)
          │
          ▼
      coded_symbols (ready for Tx.transmit)

  ## RX Flow

      received_symbols
          │
          ▼
      Symbol Demap (to soft bits)
          │
          ▼
      Deinterleave
          │
          ▼
      Depuncture (insert erasures)
          │
          ▼
      Viterbi Decode
          │
          ▼
      Scan for EOM
          │
          ▼
      decoded_bits (deliver to DTE)

  ## Usage

      # TX
      {:ok, symbols} = Codec.encode(data_bits, wid)

      # RX
      {:ok, decoder} = Codec.decoder_new(wid)
      {decoder, events} = Codec.decode(decoder, received_symbols)
      # events: [{:data, bits}, {:eom_detected, index}]
  """

  alias MinuteModemCore.Modem110D.{WID, EOM, Waveforms}
  alias MinuteModemCore.Modem110D.FEC.{ConvEncoder, Viterbi, Interleaver, Puncturer}

  require Logger
  import Bitwise

  # ===========================================================================
  # TX Encoding
  # ===========================================================================

  @doc """
  Encode data bits for transmission.

  ## Arguments
  - `data_bits` - List of data bits (0 or 1)
  - `wid` - WID struct or keyword list with :waveform, :interleaver, :constraint_length
  - `opts` - Options:
    - `:use_eom` - Append EOM pattern (default: true)
    - `:bandwidth` - Bandwidth in kHz (default: 3)

  ## Returns
  `{:ok, symbols}` - Encoded symbols ready for modulation
  """
  def encode(data_bits, wid, opts \\ []) do
    use_eom = Keyword.get(opts, :use_eom, true)
    bw_khz = Keyword.get(opts, :bandwidth, 3)

    # Extract parameters from WID
    {waveform, k, interleaver, rate, bits_per_symbol} = extract_params(wid)

    # 1. Optionally append EOM
    bits = if use_eom, do: EOM.append(data_bits), else: data_bits
    Logger.debug("[Codec.TX] Input: #{length(data_bits)} data bits, rate=#{inspect(rate)}, bps=#{bits_per_symbol}")
    Logger.debug("[Codec.TX] First 16 input bits: #{inspect(Enum.take(data_bits, 16))}")

    # 2. Convolutional encode (full-tail-biting per D.5.3.2.3)
    coded = ConvEncoder.encode_tail_biting(bits, k)
    Logger.debug("[Codec.TX] After conv encode: #{length(coded)} bits")
    Logger.debug("[Codec.TX] First 16 coded bits: #{inspect(Enum.take(coded, 16))}")

    # 3. Puncture (pass k for pattern selection)
    punctured = Puncturer.puncture(coded, rate, k: k)
    Logger.debug("[Codec.TX] After puncture: #{length(punctured)} bits")
    Logger.debug("[Codec.TX] First 16 punctured bits: #{inspect(Enum.take(punctured, 16))}")

    # 4. Interleave (now requires waveform)
    interleaved = Interleaver.interleave(punctured, waveform, interleaver, bw_khz)
    Logger.debug("[Codec.TX] After interleave: #{length(interleaved)} bits")
    Logger.debug("[Codec.TX] First 16 interleaved bits: #{inspect(Enum.take(interleaved, 16))}")

    # 5. Symbol map
    symbols = bits_to_symbols(interleaved, bits_per_symbol)
    Logger.debug("[Codec.TX] Final: #{length(symbols)} symbols")
    Logger.debug("[Codec.TX] First 16 symbols: #{inspect(Enum.take(symbols, 16))}")

    {:ok, symbols}
  end

  @doc """
  Calculate the number of symbols that will be produced for a given data size.
  """
  def encoded_symbol_count(data_bit_count, wid, opts \\ []) do
    use_eom = Keyword.get(opts, :use_eom, true)
    bw_khz = Keyword.get(opts, :bandwidth, 3)

    {waveform, _k, interleaver, rate, bits_per_symbol} = extract_params(wid)

    # Add EOM if used
    total_data_bits = if use_eom, do: data_bit_count + EOM.length(), else: data_bit_count

    # After conv encode (tail-biting): exactly 2× input bits
    coded_bits = total_data_bits * 2

    # After puncture
    punctured_bits = Puncturer.punctured_length(coded_bits, rate)

    # After interleave (may add padding) - now requires waveform
    block_size = Interleaver.block_size(waveform, interleaver, bw_khz)
    interleaved_bits = ceil(punctured_bits / block_size) * block_size

    # Symbols
    div(interleaved_bits, bits_per_symbol)
  end

  # ===========================================================================
  # RX Decoding
  # ===========================================================================

  defmodule Decoder do
    @moduledoc """
    Decoder state for RX processing.
    """

    defstruct [
      :wid,
      :waveform,
      :k,
      :interleaver,
      :rate,
      :bits_per_symbol,
      :bw_khz,
      :eom_scanner,
      :symbol_buffer,
      :bit_buffer,
      :decoded_bits,
      :eom_detected
    ]

    @type t :: %__MODULE__{
      wid: WID.t(),
      waveform: non_neg_integer(),
      k: pos_integer(),
      interleaver: atom(),
      rate: {pos_integer(), pos_integer()},
      bits_per_symbol: pos_integer(),
      bw_khz: pos_integer(),
      eom_scanner: EOM.Scanner.t(),
      symbol_buffer: [non_neg_integer()],
      bit_buffer: [0 | 1],
      decoded_bits: [0 | 1],
      eom_detected: boolean()
    }
  end

  @doc """
  Create a new decoder.

  ## Arguments
  - `wid` - WID struct or keyword list
  - `opts` - Options:
    - `:bandwidth` - Bandwidth in kHz (default: 3)
  """
  def decoder_new(wid, opts \\ []) do
    bw_khz = Keyword.get(opts, :bandwidth, 3)
    {waveform, k, interleaver, rate, bits_per_symbol} = extract_params(wid)

    {:ok, %Decoder{
      wid: wid,
      waveform: waveform,
      k: k,
      interleaver: interleaver,
      rate: rate,
      bits_per_symbol: bits_per_symbol,
      bw_khz: bw_khz,
      eom_scanner: EOM.scanner_new(),
      symbol_buffer: [],
      bit_buffer: [],
      decoded_bits: [],
      eom_detected: false
    }}
  end

  @doc """
  Decode received symbols.

  Accumulates symbols until a complete interleaver block is available,
  then decodes and scans for EOM.

  ## Arguments
  - `decoder` - Decoder state
  - `symbols` - Received symbols (hard decision)

  ## Returns
  `{decoder, events}` where events may include:
  - `{:data, bits}` - Decoded data bits
  - `{:eom_detected, bit_index}` - EOM found, transmission complete
  """
  def decode(%Decoder{eom_detected: true} = decoder, _symbols) do
    # Already done
    {decoder, []}
  end

  def decode(%Decoder{} = decoder, symbols) when is_list(symbols) do
    # Accumulate symbols
    buffer = decoder.symbol_buffer ++ symbols
    block_size_bits = Interleaver.block_size(decoder.waveform, decoder.interleaver, decoder.bw_khz)
    block_size_symbols = div(block_size_bits, decoder.bits_per_symbol)

    # Process complete blocks - accumulate soft bits
    process_blocks(decoder, buffer, block_size_symbols, [])
  end

  @doc """
  Flush accumulated soft bits through the Viterbi decoder.

  Call this when you have received all blocks and want to decode.
  For tail-biting codes, ALL blocks must be accumulated before flushing.

  Returns `{decoder, events}` with decoded data bits.
  """
  def flush(%Decoder{} = decoder) do
    flush_decode(decoder)
  end

  @doc """
  Get the number of accumulated soft bits waiting for Viterbi decode.
  """
  def accumulated_bits(%Decoder{bit_buffer: buf}), do: length(buf)

  defp process_blocks(decoder, buffer, block_size, events_acc) when length(buffer) < block_size do
    # Not enough for a complete block - just save remaining symbols
    # DON'T flush here - for tail-biting codes we need ALL bits before Viterbi
    {%{decoder | symbol_buffer: buffer}, Enum.reverse(events_acc)}
  end

  defp process_blocks(%Decoder{eom_detected: true} = decoder, buffer, _block_size, events_acc) do
    {%{decoder | symbol_buffer: buffer}, Enum.reverse(events_acc)}
  end

  defp process_blocks(decoder, buffer, block_size, events_acc) do
    # Extract one block
    block_symbols = Enum.take(buffer, block_size)
    remaining = Enum.drop(buffer, block_size)

    # Accumulate soft bits from this block (don't Viterbi decode yet)
    decoder = accumulate_block(decoder, block_symbols)

    # Continue with remaining
    process_blocks(decoder, remaining, block_size, events_acc)
  end

  # Accumulate soft bits from a block without running Viterbi yet
  defp accumulate_block(decoder, symbols) do
    # 1. Demap symbols to bits
    bits = symbols_to_bits(symbols, decoder.bits_per_symbol)

    # DEBUG: Log first 16 symbols and bits (only for first block)
    if decoder.bit_buffer == [] do
      Logger.debug("[Codec] BLOCK 1 TRACE:")
      Logger.debug("[Codec]   First 16 RX symbols: #{inspect(Enum.take(symbols, 16))}")
      Logger.debug("[Codec]   First 16 bits after demap: #{inspect(Enum.take(bits, 16))}")
    end

    # 2. Deinterleave (now requires waveform)
    deinterleaved = Interleaver.deinterleave(bits, decoder.waveform, decoder.interleaver, decoder.bw_khz)

    # DEBUG: Log first 16 bits after deinterleave (only for first block)
    if decoder.bit_buffer == [] do
      Logger.debug("[Codec]   First 16 after deinterleave: #{inspect(Enum.take(deinterleaved, 16))}")
    end

    # 3. Convert to soft values
    soft = Enum.map(deinterleaved, fn b -> if b == 0, do: 1.0, else: -1.0 end)

    # 4. Depuncture (pass k for pattern selection)
    depunctured = Puncturer.depuncture(soft, decoder.rate, k: decoder.k)

    # DEBUG: Log depuncture info (only for first block)
    if decoder.bit_buffer == [] do
      Logger.debug("[Codec]   Depuncture: #{length(soft)} soft → #{length(depunctured)} out, rate=#{inspect(decoder.rate)}")
      Logger.debug("[Codec]   First 8 depunctured: #{inspect(Enum.take(depunctured, 8) |> Enum.map(&Float.round(&1, 2)))}")
    end

    # 5. Accumulate in bit_buffer (soft bits)
    %{decoder | bit_buffer: decoder.bit_buffer ++ depunctured}
  end

  # Flush accumulated soft bits through Viterbi decoder
  defp flush_decode(%{bit_buffer: []} = decoder), do: {decoder, []}

  defp flush_decode(decoder) do
    soft_bits = length(decoder.bit_buffer)
    Logger.info("[Codec] Viterbi decode: #{soft_bits} soft bits (K=#{decoder.k})")

    # Log a sample of soft bits to see polarity
    sample_soft = decoder.bit_buffer |> Enum.take(32)
    positive_count = Enum.count(sample_soft, fn x -> x > 0 end)
    Logger.debug("[Codec] First 32 soft bits: #{positive_count} positive, #{32 - positive_count} negative")

    # Run Viterbi on all accumulated soft bits at once
    raw_decoded = Viterbi.decode_soft(decoder.bit_buffer, decoder.k)

    # Rotate to undo tail-biting reorder
    # The encoder encodes [b_{K-1}, ..., b_last, b_0, ..., b_{K-2}]
    # So the last (K-1) decoded bits are actually the first (K-1) input bits
    k_minus_1 = decoder.k - 1
    decoded = if length(raw_decoded) > k_minus_1 do
      {main_part, preload_part} = Enum.split(raw_decoded, length(raw_decoded) - k_minus_1)
      preload_part ++ main_part
    else
      raw_decoded
    end

    Logger.info("[Codec] Viterbi output: #{length(decoded)} bits = #{div(length(decoded), 8)} bytes")

    # Show first 4 decoded bytes
    first_bytes = decoded
      |> Enum.take(32)
      |> Enum.chunk_every(8)
      |> Enum.map(fn bits ->
        Enum.reduce(Enum.with_index(bits), 0, fn {bit, idx}, acc ->
          Bitwise.bor(acc, Bitwise.bsl(bit, 7 - idx))
        end)
      end)
    Logger.debug("[Codec] First 4 decoded bytes: #{inspect(first_bytes)}")

    # Scan for EOM
    {scanner, eom_events} = EOM.scan(decoder.eom_scanner, decoded)

    # Check if EOM was detected
    eom_detected = EOM.detected?(scanner)

    decoder = %{decoder |
      bit_buffer: [],  # Clear the buffer
      eom_scanner: scanner,
      eom_detected: eom_detected,
      decoded_bits: decoder.decoded_bits ++ extract_data_from_events(eom_events)
    }

    {decoder, eom_events}
  end

  # Keep old decode_block for reference/testing but it's no longer used
  defp decode_block(decoder, symbols) do
    # 1. Demap symbols to bits
    bits = symbols_to_bits(symbols, decoder.bits_per_symbol)

    # 2. Deinterleave (now requires waveform)
    deinterleaved = Interleaver.deinterleave(bits, decoder.waveform, decoder.interleaver, decoder.bw_khz)

    # 3. Convert to soft values
    soft = Enum.map(deinterleaved, fn b -> if b == 0, do: 1.0, else: -1.0 end)

    # 4. Depuncture (pass k for pattern selection)
    depunctured = Puncturer.depuncture(soft, decoder.rate, k: decoder.k)

    # 5. Viterbi decode
    raw_decoded = Viterbi.decode_soft(depunctured, decoder.k)

    # Rotate to undo tail-biting reorder
    k_minus_1 = decoder.k - 1
    decoded = if length(raw_decoded) > k_minus_1 do
      {main_part, preload_part} = Enum.split(raw_decoded, length(raw_decoded) - k_minus_1)
      preload_part ++ main_part
    else
      raw_decoded
    end

    # 6. Scan for EOM
    {scanner, eom_events} = EOM.scan(decoder.eom_scanner, decoded)

    # Check if EOM was detected
    eom_detected = EOM.detected?(scanner)

    decoder = %{decoder |
      eom_scanner: scanner,
      eom_detected: eom_detected,
      decoded_bits: decoder.decoded_bits ++ extract_data_from_events(eom_events)
    }

    {decoder, eom_events}
  end

  defp extract_data_from_events(events) do
    events
    |> Enum.filter(fn {type, _} -> type == :data end)
    |> Enum.flat_map(fn {:data, bits} -> bits end)
  end

  @doc """
  Decode a complete block of symbols in one shot (for testing).

  ## Arguments
  - `symbols` - All received symbols
  - `wid` - WID struct or keyword list
  - `opts` - Options

  ## Returns
  `{:ok, decoded_bits}` or `{:ok, decoded_bits, :eom_detected}`
  """
  def decode_block_complete(symbols, wid, opts \\ []) do
    bw_khz = Keyword.get(opts, :bandwidth, 3)
    {waveform, k, interleaver, rate, bits_per_symbol} = extract_params(wid)

    # 1. Demap
    bits = symbols_to_bits(symbols, bits_per_symbol)

    # 2. Deinterleave (now requires waveform)
    deinterleaved = Interleaver.deinterleave(bits, waveform, interleaver, bw_khz)

    # 3. Soft values
    soft = Enum.map(deinterleaved, fn b -> if b == 0, do: 1.0, else: -1.0 end)

    # 4. Depuncture (pass k for pattern selection)
    depunctured = Puncturer.depuncture(soft, rate, k: k)

    # 5. Viterbi
    raw_decoded = Viterbi.decode_soft(depunctured, k)

    # Rotate to undo tail-biting reorder
    k_minus_1 = k - 1
    decoded = if length(raw_decoded) > k_minus_1 do
      {main_part, preload_part} = Enum.split(raw_decoded, length(raw_decoded) - k_minus_1)
      preload_part ++ main_part
    else
      raw_decoded
    end

    # 6. Check for EOM
    case EOM.find_in(decoded) do
      {:found, idx} ->
        data = Enum.take(decoded, idx)
        {:ok, data, :eom_detected}
      :not_found ->
        {:ok, decoded}
    end
  end

  # ===========================================================================
  # Symbol Mapping
  # ===========================================================================

  defp bits_to_symbols(bits, bits_per_symbol) do
    bits
    |> Enum.chunk_every(bits_per_symbol)
    |> Enum.map(fn chunk ->
      # Pad if necessary
      chunk = if length(chunk) < bits_per_symbol do
        chunk ++ List.duplicate(0, bits_per_symbol - length(chunk))
      else
        chunk
      end

      # Convert bits to symbol index
      chunk
      |> Enum.with_index()
      |> Enum.reduce(0, fn {bit, idx}, acc ->
        acc ||| (bit <<< (bits_per_symbol - 1 - idx))
      end)
    end)
  end

  defp symbols_to_bits(symbols, bits_per_symbol) do
    Enum.flat_map(symbols, fn sym ->
      # Note: For BPSK, rx.ex iq_to_symbols_with_constellation already outputs 0/1
      # (not 0/4), so no special handling needed here
      for i <- (bits_per_symbol - 1)..0//-1 do
        (sym >>> i) &&& 1
      end
    end)
  end

  # ===========================================================================
  # Parameter Extraction
  # ===========================================================================

  defp extract_params(%WID{} = wid) do
    waveform = wid.waveform
    k = wid.constraint_length
    interleaver = wid.interleaver
    rate = Waveforms.code_rate(waveform)
    bits_per_symbol = WID.bits_per_symbol(wid)
    {waveform, k, interleaver, rate, bits_per_symbol}
  end

  defp extract_params(opts) when is_list(opts) do
    waveform = Keyword.get(opts, :waveform, 1)
    k = Keyword.get(opts, :constraint_length, 7)
    interleaver = Keyword.get(opts, :interleaver, :short)
    # Derive rate from waveform if not explicitly provided
    rate = Keyword.get(opts, :rate, Waveforms.code_rate(waveform))
    bits_per_symbol = Keyword.get(opts, :bits_per_symbol, 4)
    {waveform, k, interleaver, rate, bits_per_symbol}
  end
end
