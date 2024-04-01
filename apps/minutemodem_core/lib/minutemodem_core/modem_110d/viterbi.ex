defmodule MinuteModemCore.Modem110D.FEC.Viterbi do
  @moduledoc """
  Viterbi decoder for MIL-STD-188-110D convolutional codes.

  Supports K=7 (64 states) and K=9 (256 states) with rate 1/2.
  Implements soft-decision decoding with tail-biting support.

  ## Usage

      # Hard decision (bits)
      decoded = Viterbi.decode(coded_bits, 7)

      # Soft decision (LLRs or soft values)
      decoded = Viterbi.decode_soft(soft_values, 7)
  """

  import Bitwise

  @doc """
  Decode hard-decision bits.

  ## Arguments
  - `bits` - List of received bits (0 or 1), length must be even
  - `k` - Constraint length (7 or 9)

  ## Returns
  List of decoded data bits
  """
  def decode(bits, k) when k in [7, 9] and is_list(bits) do
    # Convert hard bits to soft values: 0 -> +1.0, 1 -> -1.0
    soft = Enum.map(bits, fn
      0 -> 1.0
      1 -> -1.0
    end)

    decode_soft(soft, k)
  end

  @doc """
  Decode soft-decision values.

  Supports both zero-tail and tail-biting codes by initializing all states
  with equal metrics. For tail-biting codes (per MIL-STD-188-110D D.5.3.2.3),
  the encoder starts and ends in the same state, so all states must be
  considered as potential starting points.

  ## Arguments
  - `soft` - List of soft values (positive = more likely 0, negative = more likely 1)
  - `k` - Constraint length (7 or 9)

  ## Returns
  List of decoded data bits
  """
  def decode_soft(soft, k) when k in [7, 9] and is_list(soft) do
    num_states = 1 <<< (k - 1)

    # Pair soft values into symbols (rate 1/2)
    symbols = pair_symbols(soft)

    if symbols == [] do
      []
    else
      # Build forward trellis: {state, input} -> {next_state, out1, out2}
      trellis = build_trellis(k)

      # Build reverse trellis: state -> [{prev_state, input, out1, out2}, ...]
      reverse = build_reverse_trellis(trellis, num_states)

      # Initialize path metrics - ALL states start at 0 for tail-biting support
      # (For tail-biting codes, we don't know the starting state, but it equals the ending state)
      initial_metrics =
        0..(num_states - 1)
        |> Enum.map(fn s -> {s, 0.0} end)
        |> Map.new()

      # Forward pass
      {final_metrics, survivors} =
        forward_pass(symbols, num_states, reverse, initial_metrics)

      # Traceback
      traceback(survivors, final_metrics)
    end
  end

  # ===========================================================================
  # Trellis Construction
  # ===========================================================================

  defp build_trellis(k) do
    {g1, g2} = case k do
      7 -> {0o171, 0o133}
      9 -> {0o753, 0o561}
    end

    num_states = 1 <<< (k - 1)

    for state <- 0..(num_states - 1),
        input <- 0..1,
        into: %{} do
      # Shift register: new bit enters at LSB
      # Full k-bit value for computing outputs
      full_reg = (state <<< 1) ||| input

      # Next state is lower k-1 bits of full register
      next_state = full_reg &&& (num_states - 1)

      # Compute outputs
      out1 = parity(full_reg &&& g1)
      out2 = parity(full_reg &&& g2)

      {{state, input}, {next_state, out1, out2}}
    end
  end

  defp build_reverse_trellis(trellis, num_states) do
    # For each state, find all (prev_state, input) pairs that lead to it
    for state <- 0..(num_states - 1), into: %{} do
      preds =
        for prev <- 0..(num_states - 1),
            input <- 0..1,
            {next, out1, out2} = Map.get(trellis, {prev, input}),
            next == state do
          {prev, input, out1, out2}
        end
      {state, preds}
    end
  end

  # ===========================================================================
  # Forward Pass
  # ===========================================================================

  defp forward_pass(symbols, num_states, reverse, initial_metrics) do
    Enum.reduce(symbols, {initial_metrics, []}, fn {r0, r1}, {metrics, survivors} ->
      # Compute new metrics for all states
      {new_metrics, decisions} = acs_step(metrics, num_states, reverse, r0, r1)
      {new_metrics, [decisions | survivors]}
    end)
    |> then(fn {final, surv} -> {final, Enum.reverse(surv)} end)
  end

  defp acs_step(metrics, num_states, reverse, r0, r1) do
    results =
      for state <- 0..(num_states - 1) do
        preds = Map.get(reverse, state)

        # Find best predecessor
        {best_prev, best_input, best_metric} =
          preds
          |> Enum.map(fn {prev, input, out1, out2} ->
            pm = Map.get(metrics, prev)
            bm = branch_metric(r0, r1, out1, out2)
            {prev, input, add_metrics(pm, bm)}
          end)
          |> Enum.min_by(fn {_, _, m} -> metric_value(m) end)

        {state, best_metric, best_prev, best_input}
      end

    new_metrics = Map.new(results, fn {state, metric, _, _} -> {state, metric} end)
    decisions = Enum.map(results, fn {_, _, prev, input} -> {prev, input} end)

    {new_metrics, decisions}
  end

  # ===========================================================================
  # Traceback
  # ===========================================================================

  defp traceback(survivors, final_metrics) do
    # Start from best final state
    best_state =
      final_metrics
      |> Enum.min_by(fn {_, m} -> metric_value(m) end)
      |> elem(0)

    # Trace backwards collecting input bits
    # survivors is in forward order [step0, step1, ..., stepN]
    # We need to go backwards from stepN to step0
    {bits_reversed, _} =
      survivors
      |> Enum.reverse()
      |> Enum.reduce({[], best_state}, fn decisions, {acc, state} ->
        {prev, input} = Enum.at(decisions, state)
        {[input | acc], prev}
      end)

    # bits_reversed has oldest bit first (because we prepended while going backwards)
    # So it's actually in the correct order already
    bits_reversed
  end

  # ===========================================================================
  # Branch Metric
  # ===========================================================================

  defp branch_metric(r0, r1, out1, out2) do
    # Expected: 0 -> +1, 1 -> -1
    e0 = if out1 == 0, do: 1.0, else: -1.0
    e1 = if out2 == 0, do: 1.0, else: -1.0

    # Negative correlation (lower = better match)
    -(r0 * e0 + r1 * e1)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp pair_symbols(soft) do
    soft
    |> Enum.chunk_every(2)
    |> Enum.filter(fn chunk -> length(chunk) == 2 end)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  defp add_metrics(:infinity, _), do: :infinity
  defp add_metrics(_, :infinity), do: :infinity
  defp add_metrics(a, b), do: a + b

  defp metric_value(:infinity), do: 1.0e30
  defp metric_value(x), do: x

  defp parity(x), do: parity_loop(x, 0)
  defp parity_loop(0, acc), do: acc
  defp parity_loop(x, acc), do: parity_loop(x >>> 1, bxor(acc, x &&& 1))
end
