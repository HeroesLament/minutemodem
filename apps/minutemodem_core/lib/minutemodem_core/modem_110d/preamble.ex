defmodule MinuteModemCore.Modem110D.Preamble do
  @moduledoc """
  MIL-STD-188-110D Appendix D Preamble Generation.

  Generates the synchronization preamble consisting of:
  - TLC section (AGC settling)
  - Synchronization section (M repeats of super-frame)
    - Fixed subsection
    - Downcount subsection
    - Waveform ID subsection
  """

  alias MinuteModemCore.Modem110D.Tables

  @doc """
  Build the complete preamble for a transmission.

  ## Parameters
  - `bw_khz` - Bandwidth in kHz
  - `waveform` - Waveform number (0-12)
  - `interleaver` - Interleaver option (:ultra_short, :short, :medium, :long)
  - `constraint_length` - Convolutional code constraint length (7 or 9)
  - `opts` - Options:
    - `:tlc_blocks` - Number of TLC blocks (default 0)
    - `:m` - Number of super-frame repeats (default 1)
    - `:long_fixed` - Use 9-symbol fixed section (default false, uses 1 symbol)

  ## Returns
  List of 8-PSK symbol indices (0-7)
  """
  def build(bw_khz, waveform, interleaver, constraint_length, opts \\ []) do
    tlc_blocks = Keyword.get(opts, :tlc_blocks, 0)
    m = Keyword.get(opts, :m, 1)
    long_fixed = Keyword.get(opts, :long_fixed, m > 1)

    walsh_len = Tables.walsh_length(bw_khz)

    # Build TLC section
    tlc = build_tlc(walsh_len, tlc_blocks)

    # Build synchronization section (M super-frames)
    sync = build_sync_section(bw_khz, waveform, interleaver, constraint_length, m, long_fixed)

    tlc ++ sync
  end

  # ===========================================================================
  # TLC Section (D.5.2.1.2)
  # ===========================================================================

  @doc """
  Build TLC (Transmitter Level Control) section.

  Uses complex conjugate of Fixed PN sequence.
  For 8-PSK: conjugate of symbol S is (8 - S) mod 8
  """
  def build_tlc(walsh_len, n_blocks) when n_blocks > 0 do
    fixed_pn = Tables.fixed_pn()

    # Take walsh_len symbols from fixed_pn, apply complex conjugate
    base =
      fixed_pn
      |> Enum.take(walsh_len)
      |> Enum.map(&conjugate_8psk/1)

    # Repeat N times
    List.duplicate(base, n_blocks) |> List.flatten()
  end

  def build_tlc(_walsh_len, 0), do: []

  # Complex conjugate for 8-PSK: negate the phase
  # Symbol S at phase (S * 45°) -> conjugate at phase (-S * 45°) = ((8 - S) mod 8) * 45°
  defp conjugate_8psk(0), do: 0
  defp conjugate_8psk(s), do: 8 - s

  # ===========================================================================
  # Synchronization Section (D.5.2.1.3)
  # ===========================================================================

  defp build_sync_section(bw_khz, waveform, interleaver, constraint_length, m, long_fixed) do
    walsh_len = Tables.walsh_length(bw_khz)
    wid_dibits = Tables.encode_wid(waveform, interleaver, constraint_length)

    # Build M super-frames with downcount from M-1 to 0
    (m - 1)..0//-1
    |> Enum.flat_map(fn count ->
      build_superframe(walsh_len, wid_dibits, count, long_fixed)
    end)
  end

  defp build_superframe(walsh_len, wid_dibits, downcount, long_fixed) do
    fixed = build_fixed_section(walsh_len, long_fixed)
    count = build_count_section(walsh_len, downcount)
    wid = build_wid_section(walsh_len, wid_dibits)

    fixed ++ count ++ wid
  end

  # ===========================================================================
  # Fixed Subsection
  # ===========================================================================

  defp build_fixed_section(walsh_len, false) do
    # Short mode: 1 Walsh symbol, di-bit = 3
    expand_and_scramble([3], walsh_len, :fixed)
  end

  defp build_fixed_section(walsh_len, true) do
    # Long mode: 9 Walsh symbols
    dibits = [0, 0, 2, 1, 2, 1, 0, 2, 3]
    expand_and_scramble(dibits, walsh_len, :fixed)
  end

  # ===========================================================================
  # Downcount Subsection
  # ===========================================================================

  defp build_count_section(walsh_len, count) do
    dibits = Tables.encode_downcount(count)
    expand_and_scramble(dibits, walsh_len, :count)
  end

  # ===========================================================================
  # WID Subsection
  # ===========================================================================

  defp build_wid_section(walsh_len, wid_dibits) do
    expand_and_scramble(wid_dibits, walsh_len, :wid)
  end

  # ===========================================================================
  # Walsh Expansion and Scrambling
  # ===========================================================================

  @doc """
  Expand di-bits to Walsh sequences and apply scrambling.

  1. Map each di-bit to 4-element Walsh sequence
  2. Repeat Walsh sequence to fill walsh_len
  3. Scramble with appropriate PN sequence (mod-8 addition)
  """
  def expand_and_scramble(dibits, walsh_len, pn_type) do
    pn_sequence = get_pn_sequence(pn_type)

    dibits
    |> Enum.with_index()
    |> Enum.flat_map(fn {dibit, symbol_idx} ->
      # Expand di-bit to walsh_len symbols
      walsh_base = Tables.walsh_sequence(dibit)
      expanded = expand_walsh(walsh_base, walsh_len)

      # Get PN offset for this Walsh symbol
      pn_offset = symbol_idx * walsh_len

      # Scramble with mod-8 addition
      expanded
      |> Enum.with_index()
      |> Enum.map(fn {sym, i} ->
        pn_idx = rem(pn_offset + i, 256)
        pn_val = Enum.at(pn_sequence, pn_idx)
        rem(sym + pn_val, 8)
      end)
    end)
  end

  defp get_pn_sequence(:fixed), do: Tables.fixed_pn()
  defp get_pn_sequence(:count), do: Tables.count_pn()
  defp get_pn_sequence(:wid), do: Tables.wid_pn()

  @doc """
  Expand 4-element Walsh sequence to required length by repetition.
  """
  def expand_walsh(walsh_base, target_len) do
    # Repeat the 4-element sequence to fill target_len
    repeats = div(target_len, 4)
    remainder = rem(target_len, 4)

    full = List.duplicate(walsh_base, repeats) |> List.flatten()
    partial = Enum.take(walsh_base, remainder)

    full ++ partial
  end
end
