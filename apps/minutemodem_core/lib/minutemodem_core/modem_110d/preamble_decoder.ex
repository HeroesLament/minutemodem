defmodule MinuteModemCore.Modem110D.PreambleDecoder do
  @moduledoc """
  Decodes 110D preamble from received 8-PSK symbols.

  The preamble structure (per super-frame):
  - Fixed section: 1 or 9 Walsh symbols (coarse sync)
  - Downcount: 4 Walsh symbols → 4 di-bits
  - WID: 5 Walsh symbols → 5 di-bits

  Each Walsh symbol is `walsh_length` chips (32 at 3kHz).
  Each chip is an 8-PSK symbol (0-7).

  ## Decoding Flow

      8-PSK symbols
           │
           ▼
      ┌─────────────────┐
      │ De-scramble     │  ← XOR with PN sequence (mod 8)
      └────────┬────────┘
               │
               ▼
      ┌─────────────────┐
      │ Walsh demod     │  ← Correlate against 4 Walsh sequences
      └────────┬────────┘
               │
               ▼
      ┌─────────────────┐
      │ Extract di-bits │  ← Best correlation → di-bit (0-3)
      └────────┬────────┘
               │
               ▼
      Downcount + WID structs
  """

  alias MinuteModemCore.Modem110D.{Tables, WID, Downcount}

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Decode a complete super-frame (Fixed + Downcount + WID).

  ## Arguments
  - `symbols` - List of 8-PSK symbols (0-7) for one super-frame
  - `bw_khz` - Bandwidth in kHz (determines Walsh length)
  - `opts` - Options:
    - `:long_fixed` - true if using 9-symbol Fixed section (default false)

  ## Returns
  - `{:ok, %WID{}, %Downcount{}}` on success
  - `{:error, reason}` on decode failure

  ## Super-frame structure
  - Fixed: 1 Walsh symbol (or 9 if long_fixed)
  - Downcount: 4 Walsh symbols
  - WID: 5 Walsh symbols
  """
  def decode_superframe(symbols, bw_khz, opts \\ []) do
    walsh_len = Tables.walsh_length(bw_khz)
    long_fixed = Keyword.get(opts, :long_fixed, false)

    fixed_count = if long_fixed, do: 9, else: 1
    expected_len = (fixed_count + 4 + 5) * walsh_len

    if length(symbols) < expected_len do
      {:error, {:insufficient_symbols, length(symbols), expected_len}}
    else
      # Skip Fixed section, decode Downcount and WID
      fixed_end = fixed_count * walsh_len
      count_end = fixed_end + 4 * walsh_len
      _wid_end = count_end + 5 * walsh_len

      count_symbols = Enum.slice(symbols, fixed_end, 4 * walsh_len)
      wid_symbols = Enum.slice(symbols, count_end, 5 * walsh_len)

      with {:ok, count_dibits} <- decode_count_section(count_symbols, walsh_len),
           {:ok, wid_dibits} <- decode_wid_section(wid_symbols, walsh_len),
           {:ok, downcount} <- Downcount.decode(count_dibits),
           {:ok, wid} <- WID.decode(wid_dibits) do
        {:ok, wid, downcount}
      end
    end
  end

  @doc """
  Decode just the Downcount section.

  ## Arguments
  - `symbols` - 4 * walsh_length 8-PSK symbols
  - `walsh_len` - Walsh sequence length (32, 64, etc.)
  """
  def decode_count_section(symbols, walsh_len) do
    count_pn = Tables.count_pn()
    decode_section(symbols, walsh_len, 4, count_pn)
  end

  @doc """
  Decode just the WID section.

  ## Arguments
  - `symbols` - 5 * walsh_length 8-PSK symbols
  - `walsh_len` - Walsh sequence length
  """
  def decode_wid_section(symbols, walsh_len) do
    wid_pn = Tables.wid_pn()
    decode_section(symbols, walsh_len, 5, wid_pn)
  end

  @doc """
  Decode the Fixed section (for sync verification).

  ## Arguments
  - `symbols` - walsh_length 8-PSK symbols (one Walsh symbol)
  - `walsh_len` - Walsh sequence length
  - `opts` - `:conjugate` if TLC (complex conjugate of Fixed PN)

  ## Returns
  - `{:ok, dibit}` - The detected di-bit (should be 0 for Fixed)
  - `{:error, :weak_correlation}` - If correlation is ambiguous
  """
  def decode_fixed_symbol(symbols, walsh_len, opts \\ []) do
    fixed_pn = Tables.fixed_pn()
    conjugate = Keyword.get(opts, :conjugate, false)

    pn = if conjugate do
      # Complex conjugate: negate phase → (8 - x) mod 8
      Enum.map(fixed_pn, fn x -> rem(8 - x, 8) end)
    else
      fixed_pn
    end

    case decode_section(symbols, walsh_len, 1, pn) do
      {:ok, [dibit]} -> {:ok, dibit}
      {:ok, dibits} -> {:ok, hd(dibits)}
    end
  end

  # ===========================================================================
  # Core Decoding
  # ===========================================================================

  @doc """
  Decode a section of Walsh-modulated symbols.

  ## Arguments
  - `symbols` - List of 8-PSK symbols
  - `walsh_len` - Length of one Walsh sequence
  - `num_dibits` - Number of di-bits to decode
  - `pn_sequence` - PN sequence for de-scrambling (256 symbols, cycled)

  ## Returns
  - `{:ok, [dibit, ...]}` list of di-bits (0-3)
  """
  def decode_section(symbols, walsh_len, num_dibits, pn_sequence) do
    dibits =
      symbols
      |> Enum.chunk_every(walsh_len)
      |> Enum.take(num_dibits)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, idx} ->
        # Get corresponding PN slice (wrapping if needed)
        pn_offset = rem(idx * walsh_len, length(pn_sequence))
        pn_slice = slice_cyclic(pn_sequence, pn_offset, walsh_len)

        # De-scramble and Walsh demodulate
        descrambled = descramble(chunk, pn_slice)
        walsh_demod(descrambled, walsh_len)
      end)

    {:ok, dibits}
  end

  @doc """
  De-scramble 8-PSK symbols by subtracting PN sequence (mod 8).
  """
  def descramble(symbols, pn_slice) do
    Enum.zip(symbols, pn_slice)
    |> Enum.map(fn {sym, pn} -> rem(sym - pn + 8, 8) end)
  end

  @doc """
  Walsh demodulate a sequence of de-scrambled symbols.

  Correlates against the 4 Walsh sequences and returns the
  di-bit (0-3) with highest correlation.

  ## Arguments
  - `symbols` - De-scrambled 8-PSK symbols (one Walsh period)
  - `walsh_len` - Walsh sequence length

  ## Returns
  Di-bit (0-3) with best correlation
  """
  def walsh_demod(symbols, walsh_len) do
    # Generate expanded Walsh sequences for this length
    walsh_seqs = for dibit <- 0..3 do
      base = Tables.walsh_sequence(dibit)
      expand_walsh(base, walsh_len)
    end

    # Correlate against each
    correlations =
      walsh_seqs
      |> Enum.with_index()
      |> Enum.map(fn {seq, dibit} ->
        corr = correlate_8psk(symbols, seq)
        {dibit, corr}
      end)

    # Return di-bit with max correlation
    {best_dibit, _corr} = Enum.max_by(correlations, fn {_d, c} -> c end)
    best_dibit
  end

  # ===========================================================================
  # Walsh Sequence Handling
  # ===========================================================================

  @doc """
  Expand a 4-element Walsh base sequence to full length.

  The base [a, b, c, d] is repeated to fill walsh_len.
  Example: [0,4,0,4] with walsh_len=32 becomes [0,4,0,4,0,4,0,4,...] (8 repeats)
  """
  def expand_walsh(base, walsh_len) when length(base) == 4 do
    repeats = div(walsh_len, 4)

    base
    |> List.duplicate(repeats)
    |> List.flatten()
  end

  # ===========================================================================
  # Correlation
  # ===========================================================================

  @doc """
  Correlate two 8-PSK symbol sequences.

  Uses complex correlation: sum of cos(phase_diff).
  Maximum correlation is `length` when sequences match exactly.
  """
  def correlate_8psk(received, reference) do
    Enum.zip(received, reference)
    |> Enum.map(fn {r, ref} ->
      # Phase difference in 8-PSK units (0-7 = 0° to 315°)
      phase_diff = rem(r - ref + 8, 8)
      # Convert to radians and take cos (correlation component)
      angle = phase_diff * :math.pi() / 4
      :math.cos(angle)
    end)
    |> Enum.sum()
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Slice from a list with cyclic wrapping
  defp slice_cyclic(list, start, len) do
    list_len = length(list)

    for i <- 0..(len - 1) do
      Enum.at(list, rem(start + i, list_len))
    end
  end
end
