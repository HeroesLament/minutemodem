defmodule MinuteModemCore.Modem110D.EOM do
  @moduledoc """
  End of Message (EOM) handling for MIL-STD-188-110D.

  Per D.5.4.5.1: "The HF modem shall always scan all of the decoded bits
  for the 32-bit EOM pattern defined in paragraph D.5.4.3. Upon detection
  of the EOM the modem shall return to the acquisition mode."

  ## TX Usage

      # Append EOM to data bits before FEC encoding
      data_with_eom = EOM.append(data_bits)

  ## RX Usage

      # Scan decoded bits for EOM (call continuously as bits arrive)
      {scanner, events} = EOM.scan(scanner, new_decoded_bits)
      # events may include {:eom_detected, bit_index}

  ## EOM Pattern

  The 32-bit EOM pattern from MIL-STD-188-110D D.5.4.3:
  0x4B65A5B2 (leftmost bit sent first)
  """

  import Bitwise

  # EOM pattern from MIL-STD-188-110D D.5.4.3:
  # "The EOM, expressed in hexadecimal notation is 4B65A5B2,
  #  where the left most bit is sent first."
  #
  # 0x4B = 0100 1011
  # 0x65 = 0110 0101
  # 0xA5 = 1010 0101
  # 0xB2 = 1011 0010
  @eom_pattern [
    0, 1, 0, 0, 1, 0, 1, 1,  # 0x4B
    0, 1, 1, 0, 0, 1, 0, 1,  # 0x65
    1, 0, 1, 0, 0, 1, 0, 1,  # 0xA5
    1, 0, 1, 1, 0, 0, 1, 0   # 0xB2
  ]

  @eom_length 32

  # ===========================================================================
  # TX Functions
  # ===========================================================================

  @doc """
  Get the EOM pattern as a list of bits.
  """
  def pattern, do: @eom_pattern

  @doc """
  Get the EOM pattern length in bits.
  """
  def length, do: @eom_length

  @doc """
  Append EOM pattern to data bits.

  ## Arguments
  - `data_bits` - List of data bits to transmit

  ## Returns
  List of bits with EOM appended
  """
  def append(data_bits) when is_list(data_bits) do
    data_bits ++ @eom_pattern
  end

  # ===========================================================================
  # RX Scanner
  # ===========================================================================

  defmodule Scanner do
    @moduledoc """
    Sliding window scanner for EOM detection.

    Maintains a 32-bit window and checks for pattern match
    as each new bit arrives.
    """

    defstruct [
      window: [],           # Last 32 bits
      bit_count: 0,         # Total bits scanned
      detected_at: nil      # Bit index where EOM was found (nil if not found)
    ]

    @type t :: %__MODULE__{
      window: [0 | 1],
      bit_count: non_neg_integer(),
      detected_at: non_neg_integer() | nil
    }
  end

  @doc """
  Create a new EOM scanner.
  """
  def scanner_new do
    %Scanner{}
  end

  @doc """
  Scan bits for EOM pattern.

  ## Arguments
  - `scanner` - Scanner state
  - `bits` - New decoded bits to scan

  ## Returns
  `{scanner, events}` where events is a list that may include:
  - `{:eom_detected, bit_index}` - EOM found at given bit index
  - `{:data, bits}` - Data bits to deliver to DTE (before EOM)
  """
  def scan(%Scanner{detected_at: idx} = scanner, _bits) when idx != nil do
    # Already detected, ignore further input
    {scanner, []}
  end

  def scan(%Scanner{} = scanner, bits) when is_list(bits) do
    # Process all bits, tracking which are data vs EOM
    {final_scanner, all_bits_with_eom_check} =
      Enum.reduce(bits, {scanner, []}, fn bit, {sc, acc} ->
        new_window = (sc.window ++ [bit]) |> Enum.take(-@eom_length)
        new_count = sc.bit_count + 1
        new_sc = %{sc | window: new_window, bit_count: new_count}

        # Check if this bit completes EOM
        is_eom = length(new_window) == @eom_length and new_window == @eom_pattern

        {new_sc, [{bit, new_count, is_eom} | acc]}
      end)

    # Reverse to get chronological order
    all_bits_with_eom_check = Enum.reverse(all_bits_with_eom_check)

    # Find if/where EOM was detected
    eom_info = Enum.find(all_bits_with_eom_check, fn {_bit, _count, is_eom} -> is_eom end)

    case eom_info do
      nil ->
        # No EOM found - all bits are data
        data = Enum.map(all_bits_with_eom_check, fn {bit, _count, _} -> bit end)
        events = if data != [], do: [{:data, data}], else: []
        {final_scanner, events}

      {_bit, eom_end_count, true} ->
        # EOM found - data is everything before the EOM pattern started
        eom_start = eom_end_count - @eom_length

        # Get bits before EOM started
        data =
          all_bits_with_eom_check
          |> Enum.filter(fn {_bit, count, _} -> count <= eom_start end)
          |> Enum.map(fn {bit, _count, _} -> bit end)

        # Mark scanner as detected
        final_scanner = %{final_scanner | detected_at: eom_start}

        events = []
        events = if data != [], do: [{:data, data} | events], else: events
        events = [{:eom_detected, eom_start} | events]

        {final_scanner, Enum.reverse(events)}
    end
  end

  @doc """
  Check if EOM has been detected.
  """
  def detected?(%Scanner{detected_at: nil}), do: false
  def detected?(%Scanner{}), do: true

  @doc """
  Get the bit index where EOM was detected.
  """
  def detected_at(%Scanner{detected_at: idx}), do: idx

  @doc """
  Reset scanner state.
  """
  def scanner_reset(%Scanner{} = _scanner) do
    scanner_new()
  end

  # ===========================================================================
  # Pattern Matching Utilities
  # ===========================================================================

  @doc """
  Check if a bit sequence contains the EOM pattern.

  ## Arguments
  - `bits` - List of bits to search

  ## Returns
  `{:found, index}` if EOM found at given index, `:not_found` otherwise
  """
  def find_in(bits) when is_list(bits) do
    find_in(bits, 0)
  end

  defp find_in(bits, _idx) when length(bits) < @eom_length do
    :not_found
  end

  defp find_in(bits, idx) do
    window = Enum.take(bits, @eom_length)
    if window == @eom_pattern do
      {:found, idx}
    else
      find_in(tl(bits), idx + 1)
    end
  end

  @doc """
  Convert EOM pattern to integer (for display/debugging).
  """
  def pattern_as_integer do
    @eom_pattern
    |> Enum.with_index()
    |> Enum.reduce(0, fn {bit, idx}, acc ->
      acc ||| (bit <<< (31 - idx))
    end)
  end

  @doc """
  Convert EOM pattern to hex string (for display/debugging).
  """
  def pattern_as_hex do
    Integer.to_string(pattern_as_integer(), 16)
    |> String.pad_leading(8, "0")
  end

  # ===========================================================================
  # EOT (End of Transmission) Marker
  # ===========================================================================

  @doc """
  Generate EOT marker for a given waveform/bandwidth.

  Per D.5.4.4: "The EOT shall consist of a cyclic extension of the last
  mini-probe, where the mini-probe sequence has been defined in Table D-XXI.
  The length of the cyclic extension shall be 13.333 ms (an integer multiple
  of 32 symbols for each symbol rate)."

  For 3 kHz bandwidth (2400 baud): 13.333ms = 32 symbols

  ## Arguments
  - `mini_probe` - The last mini-probe sequence
  - `bw_khz` - Bandwidth in kHz

  ## Returns
  EOT marker symbols (cyclic extension of mini-probe)
  """
  def generate_eot(mini_probe, bw_khz) do
    # 13.333 ms worth of symbols
    symbol_rate = case bw_khz do
      3 -> 2400
      6 -> 4800
      9 -> 7200
      12 -> 9600
      _ -> 2400 * bw_khz  # Approximate for other bandwidths
    end

    eot_symbols = round(0.013333 * symbol_rate)

    # Cyclic extension of mini-probe
    cyclic_extend(mini_probe, eot_symbols)
  end

  defp cyclic_extend(sequence, target_length) do
    seq_len = length(sequence)
    if seq_len == 0 do
      []
    else
      # Repeat sequence enough times, then take target_length
      repeats = div(target_length, seq_len) + 1
      sequence
      |> List.duplicate(repeats)
      |> List.flatten()
      |> Enum.take(target_length)
    end
  end
end
