defmodule MinuteModemCore.Modem110D.Sync do
  @moduledoc """
  Preamble synchronization for 110D receiver.

  Detects the presence of a 110D preamble by correlating against the
  Fixed PN sequence, recovers symbol timing, and determines whether
  we're in TLC or Sync section.

  ## Detection Strategy

  1. **Coarse search**: Correlate soft I/Q against Fixed PN (and conjugate)
  2. **Peak detection**: Find correlation peak above threshold
  3. **Timing refinement**: Determine optimal sample phase within symbol
  4. **TLC vs Sync**: Conjugate correlation indicates TLC section

  ## Usage

      # Create sync detector
      sync = Sync.new(bw_khz)

      # Feed soft I/Q samples
      case Sync.search(sync, soft_iq) do
        {:found, sync_result} ->
          # Preamble detected!
          %{timing_offset: t, sample_offset: s} = sync_result

        {:searching, updated_sync} ->
          # Need more samples
          {:continue, updated_sync}
      end
  """

  alias MinuteModemCore.Modem110D.{Tables, PreambleDecoder}

  defstruct [
    :bw_khz,
    :walsh_len,
    :fixed_pn,
    :fixed_pn_conj,
    :threshold,
    :buffer,
    :samples_per_symbol
  ]

  @type t :: %__MODULE__{
          bw_khz: pos_integer(),
          walsh_len: pos_integer(),
          fixed_pn: [0..7],
          fixed_pn_conj: [0..7],
          threshold: float(),
          buffer: [{float(), float()}],
          samples_per_symbol: pos_integer()
        }

  @doc """
  Result of successful sync detection.
  """
  defmodule Result do
    defstruct [
      :timing_offset,
      :sample_offset,
      :is_tlc,
      :correlation_peak,
      :snr_estimate
    ]

    @type t :: %__MODULE__{
            timing_offset: non_neg_integer(),
            sample_offset: non_neg_integer(),
            is_tlc: boolean(),
            correlation_peak: float(),
            snr_estimate: float() | nil
          }
  end

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Create a new sync detector.

  ## Arguments
  - `bw_khz` - Bandwidth in kHz (determines Walsh length)
  - `opts` - Options:
    - `:threshold` - Correlation threshold (default 0.6)
    - `:samples_per_symbol` - Oversampling factor (default 4)
  """
  def new(bw_khz, opts \\ []) do
    walsh_len = Tables.walsh_length(bw_khz)
    threshold = Keyword.get(opts, :threshold, 0.6)
    sps = Keyword.get(opts, :samples_per_symbol, 4)

    fixed_pn = Tables.fixed_pn() |> Enum.take(walsh_len)
    fixed_pn_conj = Enum.map(fixed_pn, &conjugate_8psk/1)

    %__MODULE__{
      bw_khz: bw_khz,
      walsh_len: walsh_len,
      fixed_pn: fixed_pn,
      fixed_pn_conj: fixed_pn_conj,
      threshold: threshold,
      buffer: [],
      samples_per_symbol: sps
    }
  end

  @doc """
  Search for preamble in soft I/Q samples.

  ## Arguments
  - `sync` - Sync detector state
  - `soft_iq` - List of {I, Q} tuples at symbol rate

  ## Returns
  - `{:found, %Result{}}` - Preamble detected with timing info
  - `{:searching, updated_sync}` - Need more samples
  """
  def search(%__MODULE__{} = sync, soft_iq) when is_list(soft_iq) do
    # Add new samples to buffer
    buffer = sync.buffer ++ soft_iq

    # Need at least one Walsh period to correlate
    if length(buffer) < sync.walsh_len do
      {:searching, %{sync | buffer: buffer}}
    else
      # Try to find correlation peak
      case find_sync(sync, buffer) do
        {:found, result, remaining} ->
          {:found, result, %{sync | buffer: remaining}}

        :not_found ->
          # Keep last walsh_len-1 samples for overlap
          keep = max(0, length(buffer) - sync.walsh_len + 1)
          {:searching, %{sync | buffer: Enum.drop(buffer, keep)}}
      end
    end
  end

  @doc """
  Correlate a single Walsh period of symbols against Fixed PN.

  Returns correlation value normalized to [-1, 1].
  """
  def correlate_fixed(%__MODULE__{} = sync, symbols) when is_list(symbols) do
    correlate_against_pn(symbols, sync.fixed_pn)
  end

  @doc """
  Correlate against conjugate Fixed PN (for TLC detection).
  """
  def correlate_tlc(%__MODULE__{} = sync, symbols) when is_list(symbols) do
    correlate_against_pn(symbols, sync.fixed_pn_conj)
  end

  @doc """
  Reset sync detector state (clear buffer).
  """
  def reset(%__MODULE__{} = sync) do
    %{sync | buffer: []}
  end

  # ===========================================================================
  # Core Detection
  # ===========================================================================

  defp find_sync(sync, buffer) do
    walsh_len = sync.walsh_len
    threshold = sync.threshold

    # Slide through buffer looking for correlation peak
    max_offset = length(buffer) - walsh_len

    if max_offset < 0 do
      :not_found
    else
      # Calculate correlations at each offset
      correlations =
        for offset <- 0..max_offset do
          symbols = buffer |> Enum.drop(offset) |> Enum.take(walsh_len)

          # Convert soft I/Q to hard 8-PSK for correlation
          hard_symbols = Enum.map(symbols, &iq_to_8psk/1)

          sync_corr = correlate_against_pn(hard_symbols, sync.fixed_pn)
          tlc_corr = correlate_against_pn(hard_symbols, sync.fixed_pn_conj)

          {offset, sync_corr, tlc_corr}
        end

      # Find best correlation
      {best_offset, best_sync, best_tlc} =
        Enum.max_by(correlations, fn {_, s, t} -> max(abs(s), abs(t)) end)

      best_corr = max(abs(best_sync), abs(best_tlc))
      is_tlc = abs(best_tlc) > abs(best_sync)

      if best_corr >= threshold do
        result = %Result{
          timing_offset: 0,  # At symbol rate, timing is implicit
          sample_offset: best_offset,
          is_tlc: is_tlc,
          correlation_peak: best_corr,
          snr_estimate: estimate_snr(best_corr)
        }

        remaining = Enum.drop(buffer, best_offset + walsh_len)
        {:found, result, remaining}
      else
        :not_found
      end
    end
  end

  # ===========================================================================
  # Correlation
  # ===========================================================================

  defp correlate_against_pn(symbols, pn) do
    # De-scramble and check if result matches di-bit 0 Walsh pattern
    # (which is all zeros after de-scrambling)
    descrambled = PreambleDecoder.descramble(symbols, pn)

    # For Fixed section, the Walsh di-bit is known (3 for short, varies for long)
    # We correlate against all 4 Walsh patterns and take the best
    correlations =
      for dibit <- 0..3 do
        walsh_seq = Tables.walsh_sequence(dibit)
        expanded = PreambleDecoder.expand_walsh(walsh_seq, length(descrambled))
        correlate_8psk_sequences(descrambled, expanded)
      end

    Enum.max(correlations)
  end

  defp correlate_8psk_sequences(seq1, seq2) do
    # Normalized correlation: sum of cos(phase_diff) / length
    len = min(length(seq1), length(seq2))

    if len == 0 do
      0.0
    else
      sum =
        Enum.zip(seq1, seq2)
        |> Enum.map(fn {a, b} ->
          phase_diff = rem(a - b + 8, 8)
          :math.cos(phase_diff * :math.pi() / 4)
        end)
        |> Enum.sum()

      sum / len
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Convert soft I/Q to hard 8-PSK symbol
  defp iq_to_8psk({i, q}) do
    angle = :math.atan2(q, i)
    angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle
    symbol = round(angle / (:math.pi() / 4))
    rem(symbol, 8)
  end

  # Complex conjugate for 8-PSK
  defp conjugate_8psk(0), do: 0
  defp conjugate_8psk(s), do: 8 - s

  # Rough SNR estimate from correlation peak
  defp estimate_snr(corr) when corr > 0 do
    # corr ≈ 1 means high SNR, corr ≈ 0 means low SNR
    # This is a rough approximation
    if corr >= 0.99 do
      30.0  # Very high SNR
    else
      10 * :math.log10(corr / (1 - corr))
    end
  end
  defp estimate_snr(_), do: nil

  # ===========================================================================
  # Streaming Interface
  # ===========================================================================

  @doc """
  Process a stream of soft I/Q, yielding sync results.

  Useful for continuous reception.
  """
  def stream_search(soft_iq_stream, bw_khz, opts \\ []) do
    sync = new(bw_khz, opts)

    Stream.transform(soft_iq_stream, sync, fn iq_chunk, sync_state ->
      case search(sync_state, iq_chunk) do
        {:found, result, updated_sync} ->
          {[{:sync, result}], updated_sync}

        {:searching, updated_sync} ->
          {[], updated_sync}
      end
    end)
  end
end
