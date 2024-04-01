defmodule MinuteModemCore.Modem110D.MiniProbe do
  @moduledoc """
  MIL-STD-188-110D Appendix D Mini-Probe Generation.

  Mini-probes are known symbol sequences inserted after each data block.
  They are used for:
  - Channel estimation
  - Phase tracking
  - Interleaver boundary detection (via cyclic shift)

  Mini-probes are PSK symbols (no scrambling applied to known symbols).
  """

  alias MinuteModemCore.Modem110D.Tables

  # ===========================================================================
  # Base Sequences (from Tables D-XXII through D-XXXVI)
  # Stored as {I, Q} tuples, converted to 8-PSK symbol indices
  # ===========================================================================

  # Length 13 base sequence (for 24-symbol mini-probe)
  @base_13 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}
  ]

  # Length 16 base sequence (for 32-symbol mini-probe)
  @base_16 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {0.0, -1.0}, {-1.0, 0.0}, {0.0, 1.0}, {1.0, 0.0}, {-1.0, 0.0},
    {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}, {-1.0, 0.0},
    {0.0, -1.0}
  ]

  # Length 19 base sequence (for 36-symbol mini-probe)
  @base_19 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0},
    {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}
  ]

  # Length 25 base sequence (for 48-symbol mini-probe)
  @base_25 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0},
    {-1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}
  ]

  # Length 36 base sequence (for 68 and 72-symbol mini-probes)
  @base_36 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0},
    {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0},
    {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}, {-1.0, 0.0}, {1.0, 0.0}
  ]

  # Length 49 base sequence (for 96-symbol mini-probe) - includes complex values
  @base_49 [
    {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0},
    {1.0, 0.0}, {1.0, 0.0}, {0.623490, -0.781832}, {-0.222521, -0.974928},
    {-0.900969, -0.433884}, {-0.900969, 0.433884}, {-0.222521, 0.974928},
    {0.623490, 0.781832}, {1.0, 0.0}, {-0.222521, -0.974928},
    {-0.900969, 0.433884}, {0.623490, 0.781832}, {0.623490, -0.781832},
    {-0.900969, -0.433884}, {-0.222521, 0.974928}, {1.0, 0.0},
    {-0.900969, -0.433884}, {0.623490, 0.781832}, {-0.222521, -0.974928},
    {-0.222521, 0.974928}, {0.623490, -0.781832}, {-0.900968, 0.433885},
    {1.0, 0.0}, {-0.900969, 0.433884}, {0.623490, -0.781832},
    {-0.222521, 0.974928}, {-0.222521, -0.974928}, {0.623490, 0.781832},
    {-0.900969, -0.433884}, {1.0, 0.0}, {-0.222521, 0.974928},
    {-0.900969, -0.433884}, {0.623490, -0.781831}, {0.623490, 0.781832},
    {-0.900969, 0.433883}, {-0.222520, -0.974928}, {1.0, 0.0},
    {0.623490, 0.781832}, {-0.222521, 0.974928}, {-0.900968, 0.433885},
    {-0.900969, -0.433884}, {-0.222520, -0.974928}, {0.623488, -0.781833}
  ]

  # Map base sequence length to the actual sequence
  @base_sequences %{
    13 => @base_13,
    16 => @base_16,
    19 => @base_19,
    25 => @base_25,
    36 => @base_36,
    49 => @base_49
    # Additional sequences would be added here for longer probes
    # 64, 81, 100, 121, 144, 169, 196, 256, 289
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Generate a mini-probe of the specified length.

  ## Parameters
  - `probe_length` - Total probe length in symbols
  - `opts` - Options:
    - `:boundary_marker` - If true, apply cyclic shift for interleaver boundary

  ## Returns
  List of 8-PSK symbol indices (0-7)
  """
  def generate(probe_length, opts \\ []) do
    boundary_marker = Keyword.get(opts, :boundary_marker, false)

    {base_len, cyclic_shift} = Tables.mini_probe_params(probe_length)

    base_sequence = get_base_sequence(base_len)

    if boundary_marker do
      # Apply cyclic shift then extend
      build_shifted_probe(base_sequence, probe_length, cyclic_shift)
    else
      # Just extend cyclically
      build_normal_probe(base_sequence, probe_length)
    end
  end

  @doc """
  Generate mini-probe for a specific waveform and bandwidth.
  """
  def generate_for_waveform(waveform, bw_khz, opts \\ []) do
    probe_length = Tables.probe_symbols(waveform, bw_khz)
    generate(probe_length, opts)
  end

  # ===========================================================================
  # Internal
  # ===========================================================================

  defp get_base_sequence(base_len) do
    case Map.get(@base_sequences, base_len) do
      nil ->
        # For sequences we haven't hardcoded, generate a placeholder
        # In production, all sequences should be defined
        raise "Base sequence of length #{base_len} not implemented"

      seq ->
        seq
    end
  end

  defp build_normal_probe(base_iq, target_length) do
    # Cyclically extend base sequence to target length
    base_iq
    |> Stream.cycle()
    |> Enum.take(target_length)
    |> Enum.map(&iq_to_8psk/1)
  end

  defp build_shifted_probe(base_iq, target_length, shift) do
    base_len = length(base_iq)

    # Start from position `shift` in the base sequence
    # Then cyclically extend to target_length
    Stream.iterate(shift, &(rem(&1 + 1, base_len)))
    |> Stream.map(&Enum.at(base_iq, &1))
    |> Enum.take(target_length)
    |> Enum.map(&iq_to_8psk/1)
  end

  @doc """
  Convert I/Q tuple to nearest 8-PSK symbol index.

  8-PSK symbols are at phases: 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
  Symbol index = phase / 45°
  """
  def iq_to_8psk({i, q}) do
    # Calculate phase angle in radians
    angle = :math.atan2(q, i)

    # Normalize to [0, 2π)
    angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle

    # Convert to symbol index (0-7)
    # Each symbol is 45° = π/4 radians apart
    symbol = round(angle / (:math.pi() / 4))

    # Handle wraparound
    rem(symbol, 8)
  end
end
