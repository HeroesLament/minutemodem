defmodule MinuteModemCore.ALE.Decoding do
  @moduledoc """
  ALE 4G Frame Decoder.

  Reverses the encoding process:
  1. Tribits → Dibits (reverse 8-PSK mapping)
  2. Dibits → Deinterleave
  3. Deinterleave → Viterbi decode (convolutional)
  4. Decoded bits → PDU parse
  """

  import Bitwise

  alias MinuteModemCore.ALE.PDU

  @spec decode_pdu(maybe_improper_list()) ::
          {:error, :invalid_length | :unknown_pdu_type | {:crc_mismatch, integer(), char()}}
          | {:ok,
             %{
               :__struct__ =>
                 MinuteModemCore.ALE.PDU.LsuConf
                 | MinuteModemCore.ALE.PDU.LsuReq
                 | MinuteModemCore.ALE.PDU.LsuTerm
                 | MinuteModemCore.ALE.PDU.TxtMessage,
               optional(:assigned_subchannels) => char(),
               optional(:called_addr) => char(),
               optional(:caller_addr) => char(),
               optional(:control) => byte(),
               optional(:countdown) => byte(),
               optional(:equipment_class) => 0 | 1 | 2 | 3,
               optional(:more) => boolean(),
               optional(:occupied_subchannels) => char(),
               optional(:reason) => byte(),
               optional(:rx_subchannels) => char(),
               optional(:snr) => byte(),
               optional(:text) => binary(),
               optional(:traffic_type) => byte(),
               optional(:tx_subchannels) => char(),
               optional(:voice) => boolean()
             }}
  @doc """
  Decode a frame's payload symbols into a PDU.
  """
  def decode_pdu(symbols) when is_list(symbols) do
    with {:ok, dibits} <- tribits_to_dibits(symbols),
         {:ok, deinterleaved} <- deinterleave(dibits),
         {:ok, decoded_bits} <- viterbi_decode(deinterleaved),
         {:ok, pdu} <- parse_pdu(decoded_bits) do
      {:ok, pdu}
    end
  end

  ## ------------------------------------------------------------------
  ## Tribit to Dibit (reverse of Encoding.dibits_to_tribits)
  ## ------------------------------------------------------------------

  # The encoder packs dibits (2 bits) into tribits (3 bits) by:
  # - Converting dibits to bit stream
  # - Re-chunking into groups of 3
  # We reverse this:
  # - Convert tribits to bit stream
  # - Re-chunk into groups of 2

  defp tribits_to_dibits(tribits) do
    bits = Enum.flat_map(tribits, fn tribit ->
      [
        band(bsr(tribit, 2), 1),
        band(bsr(tribit, 1), 1),
        band(tribit, 1)
      ]
    end)

    # Re-chunk into dibits (groups of 2 bits)
    dibits = bits
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [b1, b0] -> bor(bsl(b1, 1), b0)
        [b1] -> bsl(b1, 1)  # Pad case
      end)

    {:ok, dibits}
  end

  ## ------------------------------------------------------------------
  ## Deinterleaver
  ## ------------------------------------------------------------------

  # Reverse the interleaving applied during encoding
  # Must match the interleaver parameters in Encoding.encode_pdu

  @interleave_rows 12
  @interleave_cols 16

  defp deinterleave(dibits) do
    # Interleaver writes rows, reads columns
    # Deinterleaver writes columns, reads rows

    block_size = @interleave_rows * @interleave_cols

    # Take only what fits in the interleaver
    dibits_to_use = Enum.take(dibits, block_size)

    # Pad if needed
    padded = if length(dibits_to_use) < block_size do
      dibits_to_use ++ List.duplicate(0, block_size - length(dibits_to_use))
    else
      dibits_to_use
    end

    # Write by columns (how interleaver reads), read by rows (how interleaver writes)
    matrix = Enum.chunk_every(padded, @interleave_rows)

    deinterleaved = for row <- 0..(@interleave_rows - 1),
                        col <- 0..(@interleave_cols - 1) do
      matrix |> Enum.at(col) |> Enum.at(row)
    end

    {:ok, deinterleaved}
  end

  ## ------------------------------------------------------------------
  ## Viterbi Decoder
  ## ------------------------------------------------------------------

  # Decode rate 1/2, K=7 convolutional code
  # Polynomials match Encoding: G1 = 0b1011011, G2 = 0b1111001

  @g1 0b1011011
  @g2 0b1111001
  @num_states 64  # 2^(K-1)

  defp viterbi_decode(dibits) do
    # Initialize path metrics - state 0 starts at 0, others at infinity
    initial_metrics = Map.new(0..(@num_states - 1), fn s ->
      {s, if(s == 0, do: 0, else: 10000)}
    end)
    initial_paths = Map.new(0..(@num_states - 1), fn s -> {s, []} end)

    # Process each dibit
    {_final_metrics, final_paths} =
      Enum.reduce(dibits, {initial_metrics, initial_paths}, fn dibit, {metrics, paths} ->
        viterbi_step(metrics, paths, dibit)
      end)

    # Traceback from state 0 (assumes encoder flushed to zero state)
    decoded = Map.get(final_paths, 0, []) |> Enum.reverse()

    {:ok, decoded}
  end

  defp viterbi_step(metrics, paths, received_dibit) do
    # Convert dibit to bit pair
    received = {band(bsr(received_dibit, 1), 1), band(received_dibit, 1)}

    # For each state, find best predecessor
    new_state_data =
      for next_state <- 0..(@num_states - 1) do
        # Two possible previous states that can transition to next_state
        # If next_state = (prev_state << 1 | input) & 0x3F
        # Then prev_state could be (next_state >> 1) with input = next_state & 1

        input_bit = band(next_state, 1)
        prev_state = bsr(next_state, 1)

        # Also consider the other predecessor (with MSB set)
        prev_state_alt = bor(prev_state, 0x20)
        input_bit_alt = input_bit

        # Expected outputs for each transition
        exp = expected_output(prev_state, input_bit)
        exp_alt = expected_output(prev_state_alt, input_bit_alt)

        # Branch metrics (Hamming distance)
        bm = hamming_distance(exp, received)
        bm_alt = hamming_distance(exp_alt, received)

        # Path metrics
        pm = Map.get(metrics, prev_state, 10000) + bm
        pm_alt = Map.get(metrics, prev_state_alt, 10000) + bm_alt

        # Select survivor
        if pm <= pm_alt do
          prev_path = Map.get(paths, prev_state, [])
          {next_state, pm, [input_bit | prev_path]}
        else
          prev_path = Map.get(paths, prev_state_alt, [])
          {next_state, pm_alt, [input_bit_alt | prev_path]}
        end
      end

    # Build new metrics and paths maps
    new_metrics = Map.new(new_state_data, fn {state, metric, _} -> {state, metric} end)
    new_paths = Map.new(new_state_data, fn {state, _, path} -> {state, path} end)

    {new_metrics, new_paths}
  end

  # Compute expected output for a state transition (matches Encoding)
  defp expected_output(state, input_bit) do
    new_reg = bor(bsl(state, 1), input_bit)
    out1 = parity(band(new_reg, @g1))
    out2 = parity(band(new_reg, @g2))
    {out1, out2}
  end

  defp parity(x) do
    x
    |> Integer.digits(2)
    |> Enum.sum()
    |> rem(2)
  end

  defp hamming_distance({a1, a2}, {b1, b2}) do
    (if a1 == b1, do: 0, else: 1) + (if a2 == b2, do: 0, else: 1)
  end

  ## ------------------------------------------------------------------
  ## PDU Parsing
  ## ------------------------------------------------------------------

  defp parse_pdu(bits) do
    # Remove flush bits (last 6 bits from encoder flush)
    data_bits = Enum.drop(bits, -6)

    # Convert bits to bytes
    bytes = bits_to_bytes(data_bits)

    # Need exactly 12 bytes for PDU
    if length(bytes) >= 12 do
      pdu_bytes = Enum.take(bytes, 12) |> :erlang.list_to_binary()
      PDU.decode(pdu_bytes)
    else
      {:error, :invalid_length}
    end
  end

  defp bits_to_bytes(bits) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.filter(fn chunk -> length(chunk) == 8 end)
    |> Enum.map(fn byte_bits ->
      Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
        bor(acc, bsl(bit, 7 - idx))
      end)
    end)
  end
end
