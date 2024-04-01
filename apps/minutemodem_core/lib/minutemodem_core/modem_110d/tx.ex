defmodule MinuteModemCore.Modem110D.Tx do
  @moduledoc """
  MIL-STD-188-110D Appendix D Transmitter.

  Orchestrates the complete transmission:
  1. Preamble (TLC + sync section)
  2. Data frames (data block + mini-probe), repeated
  3. Final mini-probe

  The data symbols are expected to already be:
  - FEC encoded
  - Interleaved
  - Symbol mapped
  - Scrambled

  This module handles frame assembly and mini-probe insertion.

  ## Modulation

  Uses baseband modulation via unified_mod which handles constellation
  switching (PSK8 for preamble/probes, QAM16/32/64 for data) in a single
  pass with continuous phase.
  """

  alias MinuteModemCore.Modem110D.{Tables, Preamble, MiniProbe, EOM}
  alias MinuteModemCore.DSP.PhyModem

  require Logger

  @doc """
  Transmit a payload using 110D waveform.

  ## Parameters
  - `data_symbols` - Pre-encoded data symbols (after FEC, interleave, mapping, scrambling)
  - `config` - Transmission configuration:
    - `:waveform` - Waveform number (1-12)
    - `:bandwidth` - Bandwidth in kHz
    - `:interleaver` - Interleaver option (:ultra_short, :short, :medium, :long)
    - `:constraint_length` - Convolutional code constraint length (7 or 9)
    - `:sample_rate` - Audio sample rate in Hz
    - `:tlc_blocks` - Number of TLC blocks (default 0)
    - `:m` - Number of preamble super-frame repeats (default 1)

  ## Returns
  `{:ok, samples}` where samples is a list of i16 audio samples
  """
  def transmit(data_symbols, config) do
    waveform = Keyword.fetch!(config, :waveform)
    bw_khz = Keyword.fetch!(config, :bandwidth)
    interleaver = Keyword.fetch!(config, :interleaver)
    constraint_length = Keyword.get(config, :constraint_length, 7)
    sample_rate = Keyword.get(config, :sample_rate, 9600)
    tlc_blocks = Keyword.get(config, :tlc_blocks, 0)
    m = Keyword.get(config, :m, 1)

    # Validate waveform is not Walsh (0)
    if waveform == 0 do
      raise ArgumentError, "Waveform 0 (Walsh) uses different frame structure, not supported here"
    end

    # Build tagged symbol stream with constellation info
    tagged_symbols = build_tagged_symbol_stream(
      data_symbols, waveform, bw_khz, interleaver, constraint_length,
      tlc_blocks: tlc_blocks,
      m: m
    )

    # Modulate using unified baseband modulator
    modulate_baseband(tagged_symbols, sample_rate)
  end

  @doc """
  Build the complete symbol stream with constellation tags.

  Returns list of `{symbol, constellation}` tuples where constellation is
  one of `:psk8`, `:qam16`, `:qam32`, `:qam64`.
  """
  def build_tagged_symbol_stream(data_symbols, waveform, bw_khz, interleaver, constraint_length, opts \\ []) do
    tlc_blocks = Keyword.get(opts, :tlc_blocks, 0)
    m = Keyword.get(opts, :m, 1)

    # Get data constellation for this waveform
    data_constellation = Tables.modulation(waveform)

    # 1. Build preamble (always PSK8)
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint_length,
      tlc_blocks: tlc_blocks,
      m: m
    )
    tagged_preamble = Enum.map(preamble, fn sym -> {sym, :psk8} end)

    # 2. Initial mini-probe after preamble (PSK8)
    initial_probe = MiniProbe.generate_for_waveform(waveform, bw_khz)
    tagged_initial_probe = Enum.map(initial_probe, fn sym -> {sym, :psk8} end)

    # 3. Frame the data with mini-probes
    tagged_framed_data = frame_data_tagged(data_symbols, waveform, bw_khz, data_constellation)

    # 4. Generate EOT (cyclic extension of last mini-probe per D.5.4.4)
    # The EOT is 13.333ms of cyclic extension, tagged as PSK8
    last_probe = MiniProbe.generate_for_waveform(waveform, bw_khz)
    eot = EOM.generate_eot(last_probe, bw_khz)
    tagged_eot = Enum.map(eot, fn sym -> {sym, :psk8} end)

    Logger.debug("[Tx] Built stream: preamble=#{length(tagged_preamble)}, initial_probe=#{length(tagged_initial_probe)}, data=#{length(tagged_framed_data)}, eot=#{length(tagged_eot)}")
    Logger.debug("[Tx] EOT symbols (first 8): #{inspect(Enum.take(eot, 8))}")
    Logger.debug("[Tx] Last probe (first 8): #{inspect(Enum.take(last_probe, 8))}, total=#{length(last_probe)}")

    tagged_preamble ++ tagged_initial_probe ++ tagged_framed_data ++ tagged_eot
  end

  @doc """
  Frame data symbols with mini-probes, returning tagged tuples.

  Data symbols get tagged with the data constellation, mini-probes with PSK8.
  """
  def frame_data_tagged(data_symbols, waveform, bw_khz, data_constellation, opts \\ []) do
    mark_interleaver_boundary = Keyword.get(opts, :mark_interleaver_boundary, false)
    blocks_in_long_frame = Keyword.get(opts, :blocks_in_long_frame, nil)

    u = Tables.data_symbols(waveform, bw_khz)
    k = Tables.probe_symbols(waveform, bw_khz)

    # Split data into blocks
    blocks = chunk_data(data_symbols, u)

    # Determine which block (if any) gets the boundary marker
    boundary_block_idx =
      if mark_interleaver_boundary && blocks_in_long_frame do
        blocks_in_long_frame - 2
      else
        -1
      end

    # Build frames: each block followed by mini-probe
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      is_boundary = idx == boundary_block_idx

      # Tag data symbols with data constellation
      # For BPSK, convert 0/1 to PSK8 symbols 0/4 (180° apart) for proper modulation
      tagged_data = if data_constellation == :bpsk do
        # Log first block to verify conversion
        if idx == 0 do
          first_8 = Enum.take(block, 8)
          converted = Enum.map(first_8, fn sym -> if sym == 0, do: 0, else: 4 end)
          Logger.debug("[Tx] BPSK conversion: #{inspect(first_8)} -> #{inspect(converted)}")
        end
        Enum.map(block, fn sym ->
          psk8_sym = if sym == 0, do: 0, else: 4
          {psk8_sym, :psk8}
        end)
      else
        Enum.map(block, fn sym -> {sym, data_constellation} end)
      end

      # Generate and tag mini-probe (PSK8)
      probe = MiniProbe.generate(k, boundary_marker: is_boundary)
      tagged_probe = Enum.map(probe, fn sym -> {sym, :psk8} end)

      tagged_data ++ tagged_probe
    end)
  end

  # Chunk data into blocks of exactly `block_size` symbols
  # Pads the last block with zeros if necessary
  defp chunk_data(data, block_size) do
    data
    |> Enum.chunk_every(block_size)
    |> Enum.map(fn block ->
      if length(block) < block_size do
        # Pad with zeros (symbol 0)
        block ++ List.duplicate(0, block_size - length(block))
      else
        block
      end
    end)
  end

  @doc """
  Modulate tagged symbol stream to baseband audio samples.

  Uses unified_mod with mixed constellation support for seamless
  transitions between PSK8 (preamble/probes) and QAM (data).
  """
  def modulate_baseband(tagged_symbols, sample_rate) do
    # Create unified modulator (starts with PSK8, will switch as needed)
    mod = PhyModem.unified_mod_new(:psk8, sample_rate)

    # Modulate with mixed constellations
    samples = PhyModem.unified_mod_modulate_mixed(mod, tagged_symbols)
    tail = PhyModem.unified_mod_flush(mod)

    {:ok, samples ++ tail}
  end

  @doc """
  Build the complete symbol stream (preamble + framed data).

  Returns list of 8-PSK symbol indices.

  NOTE: This is the legacy interface that returns untagged symbols.
  For new code, use build_tagged_symbol_stream/6 instead.
  """
  def build_symbol_stream(data_symbols, waveform, bw_khz, interleaver, constraint_length, opts \\ []) do
    tlc_blocks = Keyword.get(opts, :tlc_blocks, 0)
    m = Keyword.get(opts, :m, 1)

    # 1. Build preamble
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint_length,
      tlc_blocks: tlc_blocks,
      m: m
    )

    # 2. Frame the data with mini-probes
    framed_data = frame_data(data_symbols, waveform, bw_khz)

    # 3. Add final mini-probe after preamble (per spec)
    initial_probe = MiniProbe.generate_for_waveform(waveform, bw_khz)

    # 4. Generate EOT (cyclic extension of last mini-probe per D.5.4.4)
    # The EOT is 13.333ms of cyclic extension
    last_probe = MiniProbe.generate_for_waveform(waveform, bw_khz)
    eot = EOM.generate_eot(last_probe, bw_khz)

    preamble ++ initial_probe ++ framed_data ++ eot
  end

  @doc """
  Frame data symbols with mini-probes.

  Splits data into blocks of U symbols, each followed by K-symbol mini-probe.
  The second-to-last block of a long interleaver frame gets a shifted mini-probe.
  """
  def frame_data(data_symbols, waveform, bw_khz, opts \\ []) do
    mark_interleaver_boundary = Keyword.get(opts, :mark_interleaver_boundary, false)
    blocks_in_long_frame = Keyword.get(opts, :blocks_in_long_frame, nil)

    u = Tables.data_symbols(waveform, bw_khz)
    k = Tables.probe_symbols(waveform, bw_khz)

    # Split data into blocks
    blocks = chunk_data(data_symbols, u)

    # Determine which block (if any) gets the boundary marker
    boundary_block_idx =
      if mark_interleaver_boundary && blocks_in_long_frame do
        blocks_in_long_frame - 2
      else
        -1
      end

    # Build frames: each block followed by mini-probe
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      is_boundary = idx == boundary_block_idx

      probe = MiniProbe.generate(k, boundary_marker: is_boundary)

      block ++ probe
    end)
  end

  @doc """
  Modulate symbol stream to audio samples (PSK8 only - legacy).

  NOTE: This uses carrier-based modulation. For new code, use
  modulate_baseband/2 with tagged symbols instead.
  """
  def modulate(symbols, bw_khz, sample_rate) do
    symbol_rate = Tables.symbol_rate(bw_khz)
    carrier_freq = Tables.subcarrier(bw_khz)

    mod = PhyModem.mod_new(:psk8, sample_rate, symbol_rate, carrier_freq)
    samples = PhyModem.mod_modulate(mod, symbols)
    tail = PhyModem.mod_flush(mod)

    {:ok, samples ++ tail}
  end

  @doc """
  Transmit with correct modulation per segment.

  Uses PSK8 for preamble and mini-probes, and the waveform-specific
  constellation (QAM16/32/64) for data symbols.

  NOTE: This is the legacy interface using carrier modulation.
  For new code, use transmit/2 which uses baseband modulation.
  """
  def transmit_segmented(data_symbols, config) do
    waveform = Keyword.fetch!(config, :waveform)
    bw_khz = Keyword.fetch!(config, :bandwidth)
    interleaver = Keyword.fetch!(config, :interleaver)
    constraint_length = Keyword.get(config, :constraint_length, 7)
    sample_rate = Keyword.get(config, :sample_rate, 9600)
    tlc_blocks = Keyword.get(config, :tlc_blocks, 0)
    m = Keyword.get(config, :m, 1)

    symbol_rate = Tables.symbol_rate(bw_khz)
    carrier_freq = Tables.subcarrier(bw_khz)

    # Get data constellation from waveform
    data_constellation = Tables.modulation(waveform)

    # Create modulators
    mod_psk = PhyModem.mod_new(:psk8, sample_rate, symbol_rate, carrier_freq)
    mod_data = PhyModem.mod_new(data_constellation, sample_rate, symbol_rate, carrier_freq)

    # Build preamble (PSK8)
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint_length,
      tlc_blocks: tlc_blocks, m: m)
    preamble_audio = PhyModem.mod_modulate(mod_psk, preamble)

    # Initial mini-probe after preamble (PSK8)
    initial_probe = MiniProbe.generate_for_waveform(waveform, bw_khz)
    initial_probe_audio = PhyModem.mod_modulate(mod_psk, initial_probe)

    # Frame data with probes
    u = Tables.data_symbols(waveform, bw_khz)
    k = Tables.probe_symbols(waveform, bw_khz)
    blocks = chunk_data(data_symbols, u)

    # Modulate each frame: data block (QAM) + probe (PSK8)
    framed_audio = Enum.flat_map(blocks, fn block ->
      data_audio = PhyModem.mod_modulate(mod_data, block)
      probe = MiniProbe.generate(k, boundary_marker: false)
      probe_audio = PhyModem.mod_modulate(mod_psk, probe)
      data_audio ++ probe_audio
    end)

    # Flush and combine
    tail = PhyModem.mod_flush(mod_data)

    {:ok, preamble_audio ++ initial_probe_audio ++ framed_audio ++ tail}
  end

  # ===========================================================================
  # Convenience Functions
  # ===========================================================================

  @doc """
  Calculate transmission duration in milliseconds.
  """
  def duration_ms(num_symbols, bw_khz) do
    symbol_rate = Tables.symbol_rate(bw_khz)
    num_symbols / symbol_rate * 1000
  end

  @doc """
  Calculate number of data frames for a given number of data symbols.
  """
  def num_frames(num_data_symbols, waveform, bw_khz) do
    u = Tables.data_symbols(waveform, bw_khz)
    div(num_data_symbols + u - 1, u)  # Ceiling division
  end

  @doc """
  Get total symbols for a transmission (preamble + data + probes).
  """
  def total_symbols(num_data_symbols, waveform, bw_khz, opts \\ []) do
    m = Keyword.get(opts, :m, 1)
    tlc_blocks = Keyword.get(opts, :tlc_blocks, 0)

    walsh_len = Tables.walsh_length(bw_khz)
    u = Tables.data_symbols(waveform, bw_khz)
    k = Tables.probe_symbols(waveform, bw_khz)

    # Preamble: TLC + M * (Fixed + Count + WID)
    # Fixed = 1 or 9 Walsh symbols, Count = 4, WID = 5
    fixed_symbols = if m > 1, do: 9, else: 1
    superframe_walsh_symbols = fixed_symbols + 4 + 5
    preamble_symbols = (tlc_blocks * walsh_len) + (m * superframe_walsh_symbols * walsh_len)

    # Initial mini-probe after preamble
    initial_probe = k

    # Data frames
    num_frames = num_frames(num_data_symbols, waveform, bw_khz)
    data_frame_symbols = num_frames * (u + k)

    preamble_symbols + initial_probe + data_frame_symbols
  end
end
