defmodule MinuteModemCore.Modem110D.FEC.Puncturer do
  @moduledoc """
  Puncturing and repetition for MIL-STD-188-110D FEC.

  Per TABLE D-L, code rates are achieved via:
  - **Puncturing** (rates > 1/2): Remove bits according to pattern
  - **Repetition** (rates < 1/2): Repeat conv encoder output N times

  ## Repetition Rates (TABLE D-L)

  | Rate | Method |
  |------|--------|
  | 1/8  | 1/2 repeated 4x |
  | 1/6  | 1/2 repeated 3x |
  | 1/4  | 1/2 repeated 2x |
  | 1/3  | 2/3 repeated 2x |

  ## Puncture Rates (TABLE D-L)

  | Rate | K=7 Pattern | K=9 Pattern |
  |------|-------------|-------------|
  | 3/4  | 110/101     | 111/100     |
  | 2/3  | 11/10       | 11/10       |
  | 9/16 | 111101111/111111011 | same |
  | 15/16| 9/10 pattern (complex) |

  ## Usage

      # TX: Puncture or repeat conv encoder output
      coded = Puncturer.puncture(conv_output, {1, 8})  # repeat 4x
      coded = Puncturer.puncture(conv_output, {3, 4})  # puncture

      # RX: Depuncture or combine repeated soft symbols
      soft = Puncturer.depuncture(received_soft, {1, 8})  # combine 4 copies
      soft = Puncturer.depuncture(received_soft, {3, 4})  # insert erasures
  """

  import Bitwise

  # ===========================================================================
  # Puncture Patterns (from TABLE D-L)
  # Each pattern is {g1_pattern, g2_pattern} as lists of 0/1
  # ===========================================================================

  # Rate 3/4: K=7: 110/101, K=9: 111/100
  @puncture_3_4_k7 {[1, 1, 0], [1, 0, 1]}
  @puncture_3_4_k9 {[1, 1, 1], [1, 0, 0]}

  # Rate 2/3: K=7 and K=9: 11/10
  @puncture_2_3 {[1, 1], [1, 0]}

  # Rate 9/16: 111101111/111111011 (for WID 13)
  @puncture_9_16 {[1, 1, 1, 1, 0, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 0, 1, 1]}

  # Rate 9/10: 111101110/100010001 K=7
  @puncture_9_10_k7 {[1, 1, 1, 1, 0, 1, 1, 1, 0], [1, 0, 0, 0, 1, 0, 0, 0, 1]}

  # Rate 8/9: 11110100/10001011 K=7
  @puncture_8_9_k7 {[1, 1, 1, 1, 0, 1, 0, 0], [1, 0, 0, 0, 1, 0, 1, 1]}

  # Rate 5/6: 11010/10101 K=7
  @puncture_5_6_k7 {[1, 1, 0, 1, 0], [1, 0, 1, 0, 1]}

  # Rate 4/5: 1111/1000 K=7
  @puncture_4_5_k7 {[1, 1, 1, 1], [1, 0, 0, 0]}

  # Rate 4/7: 1111/0111 K=7 and K=9
  @puncture_4_7 {[1, 1, 1, 1], [0, 1, 1, 1]}

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Puncture or repeat coded bits for transmission.

  For rates > 1/2: Removes bits according to puncture pattern
  For rates < 1/2: Repeats each pair of bits N times
  For rate 1/2: Pass through unchanged

  ## Arguments
  - `bits` - Coded bits from convolutional encoder (rate 1/2)
  - `rate` - Target code rate as `{numerator, denominator}`
  - `opts` - Options:
    - `:k` - Constraint length (7 or 9) for pattern selection (default: 7)

  ## Returns
  List of bits at the target rate
  """
  def puncture(bits, rate, opts \\ [])

  # Rate 1/2 - pass through
  def puncture(bits, {1, 2}, _opts), do: bits

  # Uncoded - pass through (for WID 11, 12)
  def puncture(bits, :uncoded, _opts), do: bits

  # Repetition rates (< 1/2)
  def puncture(bits, {1, 8}, _opts), do: repeat_bits(bits, 4)
  def puncture(bits, {1, 6}, _opts), do: repeat_bits(bits, 3)
  def puncture(bits, {1, 4}, _opts), do: repeat_bits(bits, 2)
  def puncture(bits, {1, 3}, opts) do
    # 1/3 = 2/3 punctured, then repeated 2x
    k = Keyword.get(opts, :k, 7)
    bits
    |> puncture_with_pattern(get_pattern({2, 3}, k))
    |> repeat_bits(2)
  end

  # Puncture rates (> 1/2)
  def puncture(bits, {3, 4}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({3, 4}, k))
  end

  def puncture(bits, {2, 3}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({2, 3}, k))
  end

  def puncture(bits, {9, 16}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({9, 16}, k))
  end

  def puncture(bits, {15, 16}, opts) do
    # Use 9/10 pattern as approximation (or implement exact)
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({9, 10}, k))
  end

  def puncture(bits, {9, 10}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({9, 10}, k))
  end

  def puncture(bits, {8, 9}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({8, 9}, k))
  end

  def puncture(bits, {5, 6}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({5, 6}, k))
  end

  def puncture(bits, {4, 5}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({4, 5}, k))
  end

  def puncture(bits, {4, 7}, opts) do
    k = Keyword.get(opts, :k, 7)
    puncture_with_pattern(bits, get_pattern({4, 7}, k))
  end

  # Fallback - treat unknown rates as 1/2
  def puncture(bits, rate, _opts) do
    IO.warn("Unknown puncture rate #{inspect(rate)}, passing through")
    bits
  end

  @doc """
  Depuncture or combine repeated soft symbols for decoding.

  For rates > 1/2: Inserts erasures (0.0) at punctured positions
  For rates < 1/2: Averages repeated soft symbols back to rate 1/2
  For rate 1/2: Pass through unchanged

  ## Arguments
  - `soft` - Soft symbols (positive = 0, negative = 1)
  - `rate` - Code rate as `{numerator, denominator}`
  - `opts` - Options:
    - `:k` - Constraint length (7 or 9) for pattern selection (default: 7)

  ## Returns
  List of soft symbols at rate 1/2 (ready for Viterbi)
  """
  def depuncture(soft, rate, opts \\ [])

  # Rate 1/2 - pass through
  def depuncture(soft, {1, 2}, _opts), do: soft

  # Uncoded - pass through
  def depuncture(soft, :uncoded, _opts), do: soft

  # Repetition rates - combine copies by averaging
  def depuncture(soft, {1, 8}, _opts), do: combine_repeated(soft, 4)
  def depuncture(soft, {1, 6}, _opts), do: combine_repeated(soft, 3)
  def depuncture(soft, {1, 4}, _opts), do: combine_repeated(soft, 2)
  def depuncture(soft, {1, 3}, opts) do
    # 1/3 = 2/3 punctured, then repeated 2x
    # Reverse: combine 2x, then depuncture 2/3
    k = Keyword.get(opts, :k, 7)
    soft
    |> combine_repeated(2)
    |> depuncture_with_pattern(get_pattern({2, 3}, k))
  end

  # Puncture rates - insert erasures
  def depuncture(soft, {3, 4}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({3, 4}, k))
  end

  def depuncture(soft, {2, 3}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({2, 3}, k))
  end

  def depuncture(soft, {9, 16}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({9, 16}, k))
  end

  def depuncture(soft, {15, 16}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({9, 10}, k))
  end

  def depuncture(soft, {9, 10}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({9, 10}, k))
  end

  def depuncture(soft, {8, 9}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({8, 9}, k))
  end

  def depuncture(soft, {5, 6}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({5, 6}, k))
  end

  def depuncture(soft, {4, 5}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({4, 5}, k))
  end

  def depuncture(soft, {4, 7}, opts) do
    k = Keyword.get(opts, :k, 7)
    depuncture_with_pattern(soft, get_pattern({4, 7}, k))
  end

  # Fallback
  def depuncture(soft, rate, _opts) do
    IO.warn("Unknown depuncture rate #{inspect(rate)}, passing through")
    soft
  end

  @doc """
  Calculate output length after puncturing/repetition.
  """
  def punctured_length(input_length, {1, 2}), do: input_length
  def punctured_length(input_length, :uncoded), do: input_length
  def punctured_length(input_length, {1, 8}), do: input_length * 4
  def punctured_length(input_length, {1, 6}), do: input_length * 3
  def punctured_length(input_length, {1, 4}), do: input_length * 2
  def punctured_length(input_length, {1, 3}), do: div(input_length * 3, 2) * 2  # 2/3 then 2x
  def punctured_length(input_length, {3, 4}), do: div(input_length * 3, 4)
  def punctured_length(input_length, {2, 3}), do: div(input_length * 2, 3)
  def punctured_length(input_length, {9, 16}), do: div(input_length * 9, 16)
  def punctured_length(input_length, {9, 10}), do: div(input_length * 9, 10)
  def punctured_length(input_length, rate) do
    IO.warn("Unknown rate #{inspect(rate)} for length calculation")
    input_length
  end

  # ===========================================================================
  # Pattern Selection
  # ===========================================================================

  defp get_pattern({3, 4}, 7), do: @puncture_3_4_k7
  defp get_pattern({3, 4}, 9), do: @puncture_3_4_k9
  defp get_pattern({2, 3}, _k), do: @puncture_2_3
  defp get_pattern({9, 16}, _k), do: @puncture_9_16
  defp get_pattern({9, 10}, _k), do: @puncture_9_10_k7
  defp get_pattern({8, 9}, _k), do: @puncture_8_9_k7
  defp get_pattern({5, 6}, _k), do: @puncture_5_6_k7
  defp get_pattern({4, 5}, _k), do: @puncture_4_5_k7
  defp get_pattern({4, 7}, _k), do: @puncture_4_7

  # ===========================================================================
  # Repetition (for rates < 1/2)
  # ===========================================================================

  # Repeat each pair of bits (one conv encoder output) N times
  defp repeat_bits(bits, n) do
    bits
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn pair -> List.duplicate(pair, n) |> List.flatten() end)
  end

  # Combine N repeated copies back to single copy by averaging soft values
  defp combine_repeated(soft, n) do
    chunk_size = 2 * n  # Each original pair becomes 2*n values

    soft
    |> Enum.chunk_every(chunk_size)
    |> Enum.flat_map(fn chunk ->
      # Average corresponding positions
      # chunk = [a1, b1, a2, b2, a3, b3, a4, b4] for n=4
      # Want: [avg(a1,a2,a3,a4), avg(b1,b2,b3,b4)]
      pairs = Enum.chunk_every(chunk, 2)

      if length(pairs) >= n do
        # Transpose and average
        {as, bs} = pairs |> Enum.map(fn [a, b] -> {a, b}; [a] -> {a, 0.0} end) |> Enum.unzip()
        avg_a = Enum.sum(as) / n
        avg_b = Enum.sum(bs) / n
        [avg_a, avg_b]
      else
        # Partial chunk at end, just average what we have
        count = length(pairs)
        {as, bs} = pairs |> Enum.map(fn [a, b] -> {a, b}; [a] -> {a, 0.0} end) |> Enum.unzip()
        avg_a = if count > 0, do: Enum.sum(as) / count, else: 0.0
        avg_b = if count > 0, do: Enum.sum(bs) / count, else: 0.0
        [avg_a, avg_b]
      end
    end)
  end

  # ===========================================================================
  # Pattern-based Puncturing (for rates > 1/2)
  # ===========================================================================

  # Puncture using interleaved G1/G2 pattern
  defp puncture_with_pattern(bits, {g1_pattern, g2_pattern}) do
    pattern_len = length(g1_pattern)

    # Interleave pattern: [g1[0], g2[0], g1[1], g2[1], ...]
    interleaved_pattern =
      Enum.zip(g1_pattern, g2_pattern)
      |> Enum.flat_map(fn {a, b} -> [a, b] end)

    bits
    |> Enum.with_index()
    |> Enum.filter(fn {_bit, idx} ->
      pattern_idx = rem(idx, length(interleaved_pattern))
      Enum.at(interleaved_pattern, pattern_idx) == 1
    end)
    |> Enum.map(fn {bit, _idx} -> bit end)
  end

  # Depuncture by inserting erasures (0.0) at punctured positions
  defp depuncture_with_pattern(soft, {g1_pattern, g2_pattern}) do
    # Interleave pattern
    interleaved_pattern =
      Enum.zip(g1_pattern, g2_pattern)
      |> Enum.flat_map(fn {a, b} -> [a, b] end)

    pattern_len = length(interleaved_pattern)

    # Count how many 1s in pattern (positions that were kept)
    kept_count = Enum.count(interleaved_pattern, &(&1 == 1))

    # Calculate how many complete pattern cycles we have
    num_soft = length(soft)

    # Insert erasures
    do_depuncture(soft, interleaved_pattern, pattern_len, [])
  end

  defp do_depuncture([], _pattern, _pattern_len, acc), do: Enum.reverse(acc)
  defp do_depuncture(soft, pattern, pattern_len, acc) do
    {output, remaining} = depuncture_one_cycle(soft, pattern, [])
    do_depuncture(remaining, pattern, pattern_len, Enum.reverse(output) ++ acc)
  end

  defp depuncture_one_cycle(soft, [], acc), do: {acc, soft}
  defp depuncture_one_cycle(soft, [1 | rest_pattern], acc) do
    case soft do
      [s | rest_soft] -> depuncture_one_cycle(rest_soft, rest_pattern, [s | acc])
      [] -> {acc, []}  # Ran out of soft symbols
    end
  end
  defp depuncture_one_cycle(soft, [0 | rest_pattern], acc) do
    # Insert erasure
    depuncture_one_cycle(soft, rest_pattern, [0.0 | acc])
  end
end
