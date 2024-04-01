defmodule MinuteModemCore.Modem110D.Rx do
  @moduledoc """
  MIL-STD-188-110D Receiver State Machine.

  Orchestrates synchronization, preamble decoding, and data reception.

  ## States

  - `:idle` - Not receiving, waiting for start
  - `:searching` - Looking for preamble sync
  - `:tlc_found` - Detected TLC, waiting for sync section
  - `:preamble` - Decoding super-frames, waiting for count=0
  - `:receiving` - Receiving data frames
  - `:complete` - Transmission complete

  ## Phase Ambiguity Resolution

  The demodulator outputs symbols with unknown phase rotation (0-7, representing
  0° to 315° in 45° steps). After sync detection, we try all 8 phase rotations
  and select the one that successfully decodes the preamble (valid parity).

  ## Usage

      # Create receiver
      rx = Rx.new(3)  # 3 kHz bandwidth

      # Start reception
      rx = Rx.start(rx)

      # Feed soft I/Q samples (from demodulator)
      {rx, events} = Rx.process(rx, soft_iq)

      # Handle events
      Enum.each(events, fn
        {:sync_acquired, info} -> IO.puts("Sync!")
        {:wid_decoded, wid} -> IO.puts("WID: \#{inspect(wid)}")
        {:data, symbols} -> handle_data(symbols)
        {:complete, stats} -> IO.puts("Done!")
      end)
  """

  require Logger

  alias MinuteModemCore.Modem110D.{Sync, PreambleDecoder, WID, Downcount, Tables, MiniProbeRx, EOM}
  alias MinuteModemCore.DSP.DemodOutput

  # ===========================================================================
  # State Structure
  # ===========================================================================

  defstruct [
    # Configuration
    :bw_khz,
    :sample_rate,

    # State machine
    :state,

    # Sync detector
    :sync,

    # Phase ambiguity resolution
    :phase_offset,        # Resolved phase offset (0-7), nil until resolved

    # Decoded preamble info
    :wid,
    :last_count,
    :superframes_received,

    # Buffers
    :symbol_buffer,
    :iq_buffer,
    :data_iq_buffer,      # I/Q buffer for data frames (for channel correction)

    # Mini-probe processing
    :mini_probe_rx,       # MiniProbeRx processor
    :frames_received,     # Count of data frames received

    # EOM scanning
    :eom_scanner,         # EOM scanner for decoded bits

    # Timing
    :timing_offset,

    # Statistics
    :stats
  ]

  @type state :: :idle | :searching | :tlc_found | :preamble | :receiving | :complete

  @type t :: %__MODULE__{
          bw_khz: pos_integer(),
          sample_rate: pos_integer(),
          state: state(),
          sync: Sync.t(),
          phase_offset: non_neg_integer() | nil,
          wid: WID.t() | nil,
          last_count: integer() | nil,
          superframes_received: non_neg_integer(),
          symbol_buffer: [non_neg_integer()],
          iq_buffer: [{float(), float()}],
          timing_offset: non_neg_integer() | nil,
          stats: map()
        }

  @type event ::
          {:state_changed, state(), state()}
          | {:sync_acquired, map()}
          | {:tlc_detected, map()}
          | {:wid_decoded, WID.t()}
          | {:countdown, non_neg_integer()}
          | {:data_start, WID.t()}
          | {:data, [non_neg_integer()]}
          | {:channel_estimate, map()}
          | {:interleaver_boundary, non_neg_integer()}
          | {:eot_detected, map()}
          | {:complete, map()}
          | {:error, term()}

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Create a new receiver.

  ## Arguments
  - `bw_khz` - Bandwidth in kHz (3, 6, 9, 12, etc.)
  - `opts` - Options:
    - `:sample_rate` - Audio sample rate (default 9600)
    - `:sync_threshold` - Correlation threshold (default 0.5)
  """
  def new(bw_khz, opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    sync_threshold = Keyword.get(opts, :sync_threshold, 0.5)

    %__MODULE__{
      bw_khz: bw_khz,
      sample_rate: sample_rate,
      state: :idle,
      sync: Sync.new(bw_khz, threshold: sync_threshold),
      phase_offset: nil,
      wid: nil,
      last_count: nil,
      superframes_received: 0,
      symbol_buffer: [],
      iq_buffer: [],
      data_iq_buffer: [],
      mini_probe_rx: nil,
      frames_received: 0,
      eom_scanner: EOM.scanner_new(),
      timing_offset: nil,
      stats: %{
        sync_time: nil,
        wid_decode_time: nil,
        data_start_time: nil,
        symbols_received: 0,
        frames_received: 0,
        resync_count: 0,
        channel_estimates: [],
        avg_snr: nil
      }
    }
  end

  @doc """
  Start the receiver (transition to searching state).

  Per MIL-STD-188-110D Section 5.1, full-duplex operation requires the receiver
  to be ready for acquisition after completing a reception. This enables ARQ
  turnaround where we receive data, send ACK, then immediately receive again.
  """
  def start(%__MODULE__{state: :idle} = rx) do
    Logger.debug("[Modem110D.Rx] PhyRx.start: :idle → :searching")
    {%{rx | state: :searching, stats: %{rx.stats | sync_time: now()}},
     [{:state_changed, :idle, :searching}]}
  end

  def start(%__MODULE__{state: :complete} = rx) do
    # After EOT, reset and return to searching (per 188-110D full-duplex operation)
    Logger.debug("[Modem110D.Rx] PhyRx.start: :complete → :searching (full-duplex reset)")
    rx = reset_buffers(rx)
    {%{rx | state: :searching, stats: %{rx.stats | sync_time: now()}},
     [{:state_changed, :complete, :searching}]}
  end

  def start(%__MODULE__{state: state} = rx) do
    Logger.debug("[Modem110D.Rx] PhyRx.start: already in #{state}, no-op")
    {rx, []}
  end

  @doc """
  Stop the receiver (transition to idle state).
  """
  def stop(%__MODULE__{} = rx) do
    old_state = rx.state
    {%{rx | state: :idle} |> reset_buffers(),
     [{:state_changed, old_state, :idle}]}
  end

  @doc """
  Process soft I/Q samples.

  ## Arguments
  - `rx` - Receiver state
  - `soft_iq` - Either `%DemodOutput.IQ{}` or list of `{i, q}` tuples

  ## Returns
  `{updated_rx, events}` where events is a list of receiver events
  """
  def process(%__MODULE__{} = rx, %DemodOutput.IQ{data: iq}) do
    process(rx, iq)
  end

  def process(%__MODULE__{state: :idle} = rx, _iq), do: {rx, []}

  def process(%__MODULE__{state: :searching} = rx, iq) do
    process_searching(rx, iq)
  end

  def process(%__MODULE__{state: :tlc_found} = rx, iq) do
    process_tlc_found(rx, iq)
  end

  def process(%__MODULE__{state: :preamble} = rx, iq) do
    process_preamble(rx, iq)
  end

  def process(%__MODULE__{state: :receiving} = rx, iq) do
    process_receiving(rx, iq)
  end

  def process(%__MODULE__{state: :complete} = rx, _iq) do
    Logger.warning("[Modem110D.Rx] PhyRx.process: samples IGNORED - stuck in :complete state!")
    {rx, []}
  end

  @doc """
  Flush any buffered data at end of transmission.

  Call this when you know the transmission has ended (e.g., carrier lost,
  timeout, or EOT detected). This will process any partial frame remaining
  in the buffer.

  Returns `{updated_rx, events}` where events may include a final `:data` event
  with the partial frame's symbols.
  """
  def flush(%__MODULE__{state: :receiving, data_iq_buffer: buffer, wid: wid} = rx) when buffer != [] do
    # Process partial frame if we have data
    u = Tables.data_symbols(wid.waveform, rx.bw_khz)
    k = Tables.probe_symbols(wid.waveform, rx.bw_khz)
    constellation = WID.constellation(wid)

    buffer_len = length(buffer)
    data_len = if buffer_len >= k do
      buffer_len - k
    else
      buffer_len
    end

    data_len = min(data_len, u)

    data_iq = Enum.take(buffer, max(data_len, 0))

    corrected_iq = if rx.mini_probe_rx && data_iq != [] do
      case MiniProbeRx.last_estimate(rx.mini_probe_rx) do
        nil -> data_iq
        est -> MiniProbeRx.correct_channel(data_iq, est)
      end
    else
      data_iq
    end

    data_symbols = iq_to_symbols_with_constellation(corrected_iq, constellation)

    events = if data_symbols != [] do
      [{:data, data_symbols}, {:flushed, %{symbols: length(data_symbols)}}]
    else
      [{:flushed, %{symbols: 0}}]
    end

    rx = %{rx |
      data_iq_buffer: [],
      state: :complete
    }

    {rx, events}
  end

  def flush(%__MODULE__{} = rx), do: {rx, [{:flushed, %{symbols: 0}}]}

  @doc """
  Get current receiver state.
  """
  def state(%__MODULE__{state: s}), do: s

  @doc """
  Get decoded WID (nil if not yet decoded).
  """
  def wid(%__MODULE__{wid: w}), do: w

  @doc """
  Check if receiver is synchronized.
  """
  def synchronized?(%__MODULE__{state: s}) when s in [:preamble, :receiving], do: true
  def synchronized?(%__MODULE__{}), do: false

  @doc """
  Get receiver statistics.
  """
  def stats(%__MODULE__{stats: s}), do: s

  # ===========================================================================
  # State: Searching
  # ===========================================================================

  defp process_searching(rx, iq) do
    buffer = rx.iq_buffer ++ iq

    case Sync.search(%{rx.sync | buffer: buffer}, []) do
      {:found, sync_result, updated_sync} ->

        if sync_result.is_tlc do
          rx = %{rx |
            state: :tlc_found,
            sync: updated_sync,
            iq_buffer: updated_sync.buffer,
            timing_offset: sync_result.timing_offset
          }
          events = [
            {:state_changed, :searching, :tlc_found},
            {:tlc_detected, %{
              correlation: sync_result.correlation_peak,
              snr_estimate: sync_result.snr_estimate
            }}
          ]

          if updated_sync.buffer != [] do
            {rx2, more_events} = process_tlc_found(rx, [])
            {rx2, events ++ more_events}
          else
            {rx, events}
          end
        else
          handle_sync_found(rx, sync_result, updated_sync)
        end

      {:searching, updated_sync} ->
        {%{rx | sync: updated_sync, iq_buffer: updated_sync.buffer}, []}
    end
  end

  # ===========================================================================
  # State: TLC Found
  # ===========================================================================

  defp process_tlc_found(rx, iq) do
    buffer = rx.iq_buffer ++ iq
    search_for_sync(rx, buffer)
  end

  defp search_for_sync(rx, buffer) do
    case Sync.search(%{rx.sync | buffer: buffer}, []) do
      {:found, sync_result, updated_sync} ->

        if sync_result.is_tlc do
          if updated_sync.buffer != [] do
            search_for_sync(%{rx | sync: updated_sync}, updated_sync.buffer)
          else
            {%{rx | sync: updated_sync, iq_buffer: []}, []}
          end
        else
          handle_sync_found(rx, sync_result, updated_sync)
        end

      {:searching, updated_sync} ->
        {%{rx | sync: updated_sync, iq_buffer: updated_sync.buffer}, []}
    end
  end

  defp handle_sync_found(rx, sync_result, updated_sync) do
    remaining_iq = updated_sync.buffer

    rx = %{rx |
      state: :preamble,
      sync: Sync.reset(updated_sync),
      iq_buffer: [],
      symbol_buffer: [],
      phase_offset: nil,  # Will be resolved during preamble decode
      timing_offset: sync_result.timing_offset,
      stats: %{rx.stats | sync_time: now() - (rx.stats.sync_time || now())}
    }

    events = [
      {:state_changed, :searching, :preamble},
      {:sync_acquired, %{
        correlation: sync_result.correlation_peak,
        snr_estimate: sync_result.snr_estimate,
        sample_offset: sync_result.sample_offset
      }}
    ]

    if remaining_iq != [] do
      {rx2, more_events} = process_preamble(rx, remaining_iq)
      {rx2, events ++ more_events}
    else
      {rx, events}
    end
  end

  # ===========================================================================
  # State: Preamble
  # ===========================================================================

  defp process_preamble(rx, iq) do
    symbols = iq_to_symbols(iq)
    symbol_buffer = rx.symbol_buffer ++ symbols
    iq_buffer = rx.iq_buffer ++ iq

    walsh_len = Tables.walsh_length(rx.bw_khz)

    if rx.superframes_received == 0 do
      # Need at least Count(4) + WID(5) = 9 Walsh symbols to attempt decode
      min_needed = (4 + 5) * walsh_len

      if length(symbol_buffer) >= min_needed do
        # Try to decode first superframe - this will try both short and long fixed
        {rx, symbol_buffer, iq_buffer, events} = decode_first_superframe(rx, symbol_buffer, iq_buffer, walsh_len, [])
        {rx, symbol_buffer, iq_buffer, more_events} = maybe_decode_more_superframes(rx, symbol_buffer, iq_buffer, walsh_len)
        {%{rx | symbol_buffer: symbol_buffer, iq_buffer: iq_buffer}, events ++ more_events}
      else
        {%{rx | symbol_buffer: symbol_buffer, iq_buffer: iq_buffer}, []}
      end
    else
      {rx, symbol_buffer, iq_buffer, events} = maybe_decode_more_superframes(rx, symbol_buffer, iq_buffer, walsh_len)
      {%{rx | symbol_buffer: symbol_buffer, iq_buffer: iq_buffer}, events}
    end
  end

  defp maybe_decode_more_superframes(rx, symbol_buffer, iq_buffer, walsh_len) do
    superframe_len = (9 + 4 + 5) * walsh_len

    if rx.state == :receiving do
      {rx, symbol_buffer, iq_buffer, []}
    else
      decode_superframes(rx, symbol_buffer, iq_buffer, superframe_len, true, [])
    end
  end

  # Decode first super-frame with phase ambiguity AND fixed-length ambiguity resolution
  # We don't know if TX used m=1 (short fixed) or m>1 (long fixed), so try both.
  # We also try different base offsets to handle:
  # - Demodulator settling period (~12 symbols of garbage)
  # - Sync buffer positioning variations
  # Combined: up to 8 phases × 2 fixed lengths × multiple offsets
  defp decode_first_superframe(rx, symbol_buffer, iq_buffer, walsh_len, events_acc) do
    count_wid_len = (4 + 5) * walsh_len  # 288 symbols at 3kHz

    # Skip values to try:
    # - 0: Sync consumed Fixed, buffer starts at Count
    # - walsh_len (32): Buffer starts at Fixed, skip to Count
    # - 8*walsh_len (256): Long fixed, skip 8 more Fixed after sync
    # - 9*walsh_len (288): Buffer starts at Fixed (long), skip all Fixed to Count
    skips_to_try = [0, walsh_len, 8 * walsh_len, 9 * walsh_len]

    # Also try a few base offsets for demod settling / sync misalignment
    base_offsets = [0, 4, 8, 12, 16]

    result = Enum.find_value(base_offsets, fn base_offset ->
      Enum.find_value(skips_to_try, fn skip ->
        total_skip = base_offset + skip
        needed = total_skip + count_wid_len

        if length(symbol_buffer) >= needed do
          Enum.find_value(0..7, fn phase_offset ->
            rotated = Enum.map(symbol_buffer, fn s -> rem(s - phase_offset + 8, 8) end)

            buffer_after_skip = Enum.drop(rotated, total_skip)
            count_symbols = Enum.take(buffer_after_skip, 4 * walsh_len)
            wid_symbols = Enum.slice(buffer_after_skip, 4 * walsh_len, 5 * walsh_len)

            with {:ok, count_dibits} <- PreambleDecoder.decode_count_section(count_symbols, walsh_len),
                 {:ok, wid_dibits} <- PreambleDecoder.decode_wid_section(wid_symbols, walsh_len),
                 {:ok, downcount} <- Downcount.decode(count_dibits),
                 {:ok, wid} <- WID.decode(wid_dibits) do
              {:ok, phase_offset, downcount, wid, rotated, total_skip, base_offset, skip}
            else
              _ -> nil
            end
          end)
        else
          nil
        end
      end)
    end)

    case result do
      {:ok, phase_offset, downcount, wid, rotated_symbols, total_skip, base_offset, skip} ->
        needed = total_skip + count_wid_len
        Logger.debug("[Modem110D.Rx] Decode success: phase=#{phase_offset * 45}°, base_offset=#{base_offset}, skip=#{skip}")

        remaining_symbols = Enum.drop(rotated_symbols, needed)
        remaining_iq = Enum.drop(iq_buffer, needed)

        rx = %{rx |
          wid: wid,
          last_count: downcount.count,
          superframes_received: rx.superframes_received + 1,
          phase_offset: phase_offset
        }

        new_events = build_preamble_events(rx, wid, downcount)

        if Downcount.final?(downcount) do
          rx = %{rx |
            state: :receiving,
            symbol_buffer: [],
            data_iq_buffer: remaining_iq,
            stats: %{rx.stats |
              wid_decode_time: now(),
              data_start_time: now()
            }
          }
          state_events = [
            {:state_changed, :preamble, :receiving},
            {:data_start, wid}
          ]

          rx = maybe_init_mini_probe_rx(rx)
          {rx, data_events} = process_buffered_iq_frames(rx)

          final_events = events_acc ++ new_events ++ state_events ++ data_events
          {rx, [], [], final_events}
        else
          {rx, remaining_symbols, remaining_iq, events_acc ++ new_events}
        end

      nil ->
        events = events_acc ++ [{:error, {:preamble_decode_failed, :parity_mismatch}}]
        {rx, symbol_buffer, iq_buffer, events}
    end
  end

  defp decode_superframes(rx, symbol_buffer, iq_buffer, superframe_len, long_fixed, events_acc) do
    if length(symbol_buffer) >= superframe_len do
      sf_symbols = Enum.take(symbol_buffer, superframe_len)
      remaining_symbols = Enum.drop(symbol_buffer, superframe_len)
      remaining_iq = Enum.drop(iq_buffer, superframe_len)

      # Apply known phase offset if available, otherwise try all phases
      result = if rx.phase_offset do
        # Use known phase
        rotated = Enum.map(sf_symbols, fn s -> rem(s - rx.phase_offset + 8, 8) end)
        case PreambleDecoder.decode_superframe(rotated, rx.bw_khz, long_fixed: long_fixed) do
          {:ok, wid, downcount} -> {:ok, rx.phase_offset, wid, downcount, rotated}
          {:error, _} -> nil
        end
      else
        # Try all phases (shouldn't happen if first superframe resolved it)
        Enum.find_value(0..7, fn phase_offset ->
          rotated = Enum.map(sf_symbols, fn s -> rem(s - phase_offset + 8, 8) end)
          case PreambleDecoder.decode_superframe(rotated, rx.bw_khz, long_fixed: long_fixed) do
            {:ok, wid, downcount} -> {:ok, phase_offset, wid, downcount, rotated}
            {:error, _} -> nil
          end
        end)
      end

      case result do
        {:ok, phase_offset, wid, downcount, _rotated} ->
          rx = %{rx |
            wid: wid,
            last_count: downcount.count,
            superframes_received: rx.superframes_received + 1,
            phase_offset: phase_offset
          }

          new_events = build_preamble_events(rx, wid, downcount)

          if Downcount.final?(downcount) do
            rx = %{rx |
              state: :receiving,
              symbol_buffer: [],
              data_iq_buffer: remaining_iq,
              stats: %{rx.stats |
                wid_decode_time: now(),
                data_start_time: now()
              }
            }

            rx = maybe_init_mini_probe_rx(rx)
            {rx, data_events} = process_buffered_iq_frames(rx)

            final_events = events_acc ++ new_events ++ [
              {:state_changed, :preamble, :receiving},
              {:data_start, wid}
            ] ++ data_events
            {rx, [], [], final_events}
          else
            decode_superframes(rx, remaining_symbols, remaining_iq, superframe_len, true, events_acc ++ new_events)
          end

        nil ->
          events = events_acc ++ [{:error, {:preamble_decode_failed, :parity_mismatch}}]
          {rx, symbol_buffer, iq_buffer, events}
      end
    else
      {rx, symbol_buffer, iq_buffer, events_acc}
    end
  end

  defp build_preamble_events(rx, wid, downcount) do
    events = []

    events = if rx.superframes_received == 1 do
      [{:wid_decoded, wid} | events]
    else
      events
    end

    [{:countdown, downcount.count} | events]
    |> Enum.reverse()
  end

  # ===========================================================================
  # State: Receiving
  # ===========================================================================

  defp process_receiving(rx, iq) do
    rx = maybe_init_mini_probe_rx(rx)

    buffer = rx.data_iq_buffer ++ iq

    wf = rx.wid.waveform
    u = Tables.data_symbols(wf, rx.bw_khz)
    k = Tables.probe_symbols(wf, rx.bw_khz)
    frame_len = u + k

    process_data_frames(rx, buffer, frame_len, u, k, [])
  end

  defp process_buffered_iq_frames(%{data_iq_buffer: []} = rx), do: {rx, []}
  defp process_buffered_iq_frames(%{data_iq_buffer: buffer, wid: wid} = rx) do
    wf = wid.waveform
    u = Tables.data_symbols(wf, rx.bw_khz)
    k = Tables.probe_symbols(wf, rx.bw_khz)
    frame_len = u + k

    # Skip first mini-probe (comes before first data frame)
    buffer = Enum.drop(buffer, k)

    process_data_frames(rx, buffer, frame_len, u, k, [])
  end

  defp maybe_init_mini_probe_rx(%{mini_probe_rx: nil, wid: wid, bw_khz: bw} = rx) when wid != nil do
    %{rx | mini_probe_rx: MiniProbeRx.new(wid.waveform, bw)}
  end
  defp maybe_init_mini_probe_rx(rx), do: rx

  defp process_data_frames(rx, buffer, frame_len, _u, _k, events_acc) when length(buffer) < frame_len do
    # Buffer too small for another frame - check if this is EOT
    # EOT is 32 symbols (at 3kHz), so if we have >= 32 symbols, try EOT detection
    rx = maybe_init_mini_probe_rx(rx)

    eot_result = if rx.mini_probe_rx != nil and length(buffer) >= 32 do
      MiniProbeRx.detect_eot(rx.mini_probe_rx, buffer)
    else
      :not_eot
    end

    # Log EOT check result for final buffer
    corr_str = case eot_result do
      {:eot_detected, c} -> "DETECTED (#{Float.round(c, 3)})"
      :not_eot -> "not_eot"
    end
    Logger.debug("[Modem110D.Rx] Final EOT check: buffer=#{length(buffer)} symbols, result=#{corr_str}")

    case eot_result do
      {:eot_detected, corr} ->
        Logger.info("[Modem110D.Rx] EOT detected with correlation #{Float.round(corr, 3)}")
        rx = %{rx | state: :complete, data_iq_buffer: []}
        final_events = [{:eot_detected, %{correlation: corr}} | events_acc]
        final_events = [{:complete, rx.stats} | final_events]
        final_events = [{:state_changed, :receiving, :complete} | final_events]
        {rx, Enum.reverse(final_events)}

      :not_eot ->
        # Not EOT, just save remaining buffer
        {%{rx | data_iq_buffer: buffer}, Enum.reverse(events_acc)}
    end
  end

  defp process_data_frames(rx, buffer, frame_len, u, k, events_acc) do
    frame_iq = Enum.take(buffer, frame_len)
    remaining = Enum.drop(buffer, frame_len)

    {corrected_data_iq, updated_probe_rx, probe_events} =
      MiniProbeRx.process_frame(rx.mini_probe_rx, frame_iq)

    constellation = WID.constellation(rx.wid)
    data_symbols = iq_to_symbols_with_constellation(corrected_data_iq, constellation)

    eot_result = MiniProbeRx.detect_eot(updated_probe_rx, remaining)

    frames_received = rx.frames_received + 1
    channel_est = MiniProbeRx.last_estimate(updated_probe_rx)

    rx = %{rx |
      mini_probe_rx: updated_probe_rx,
      frames_received: frames_received,
      stats: update_channel_stats(rx.stats, channel_est, frames_received)
    }

    new_events = []

    new_events = if data_symbols != [] do
      [{:data, data_symbols} | new_events]
    else
      new_events
    end

    new_events = if channel_est do
      [{:channel_estimate, %{
        frame: frames_received,
        amplitude: channel_est.amplitude,
        phase_deg: channel_est.phase * 180 / :math.pi(),
        snr_db: channel_est.snr_estimate
      }} | new_events]
    else
      new_events
    end

    new_events = Enum.reduce(probe_events, new_events, fn
      {:boundary_detected}, acc -> [{:interleaver_boundary, frames_received} | acc]
      _, acc -> acc
    end)

    case eot_result do
      {:eot_detected, corr} ->
        Logger.info("[Modem110D.Rx] EOT detected with correlation #{corr}")
        rx = %{rx |
          state: :complete,
          data_iq_buffer: []
        }
        final_events = [{:eot_detected, %{correlation: corr, frame: frames_received}} | new_events]
        final_events = [{:complete, rx.stats} | final_events]
        final_events = [{:state_changed, :receiving, :complete} | final_events]
        {rx, Enum.reverse(final_events ++ events_acc)}

      :not_eot ->
        process_data_frames(rx, remaining, frame_len, u, k, new_events ++ events_acc)
    end
  end

  defp update_channel_stats(stats, nil, _frame), do: stats
  defp update_channel_stats(stats, channel_est, frame) do
    estimates = [channel_est | Map.get(stats, :channel_estimates, [])] |> Enum.take(20)

    avg_snr = if length(estimates) > 0 do
      Enum.sum(Enum.map(estimates, & &1.snr_estimate)) / length(estimates)
    else
      nil
    end

    %{stats |
      symbols_received: stats.symbols_received + 256,
      frames_received: frame,
      channel_estimates: estimates,
      avg_snr: avg_snr
    }
  end

  # ===========================================================================
  # Symbol Conversion
  # ===========================================================================

  defp iq_to_symbols(iq) do
    Enum.map(iq, fn {i, q} ->
      angle = :math.atan2(q, i)
      angle = if angle < 0, do: angle + 2 * :math.pi(), else: angle
      symbol = round(angle / (:math.pi() / 4))
      rem(symbol, 8)
    end)
  end

  defp iq_to_symbols_with_constellation(iq, :bpsk) do
    Enum.map(iq, fn {i, _q} -> if i >= 0, do: 0, else: 1 end)
  end

  defp iq_to_symbols_with_constellation(iq, :qpsk) do
    Enum.map(iq, fn {i, q} ->
      case {i >= 0, q >= 0} do
        {true, true} -> 0
        {false, true} -> 1
        {false, false} -> 3
        {true, false} -> 2
      end
    end)
  end

  defp iq_to_symbols_with_constellation(iq, :psk8) do
    iq_to_symbols(iq)
  end

  defp iq_to_symbols_with_constellation(iq, constellation)
       when constellation in [:qam16, :qam32, :qam64, :qam256] do
    Enum.map(iq, fn {i, q} ->
      slice_qam(i, q, constellation)
    end)
  end

  defp iq_to_symbols_with_constellation(iq, :walsh) do
    iq_to_symbols(iq)
  end

  @qam16_110d_constellation %{
    0  => { 0.866025,  0.500000},
    1  => { 1.000000,  0.000000},
    2  => { 0.500000,  0.866025},
    3  => { 0.258819,  0.258819},
    4  => {-0.500000,  0.866025},
    5  => { 0.000000,  1.000000},
    6  => {-0.866025,  0.500000},
    7  => {-0.258819,  0.258819},
    8  => { 0.500000, -0.866025},
    9  => { 0.000000, -1.000000},
    10 => { 0.866025, -0.500000},
    11 => { 0.258819, -0.258819},
    12 => {-0.866025, -0.500000},
    13 => {-0.500000, -0.866025},
    14 => {-1.000000,  0.000000},
    15 => {-0.258819, -0.258819}
  }

  defp slice_qam(i, q, :qam16) do
    {symbol, _dist} = Enum.min_by(@qam16_110d_constellation, fn {_sym, {ci, cq}} ->
      di = i - ci
      dq = q - cq
      di * di + dq * dq
    end)
    symbol
  end

  defp slice_qam(i, q, :qam64) do
    i_bits = qam64_axis(i)
    q_bits = qam64_axis(q)
    Bitwise.bor(Bitwise.bsl(i_bits, 3), q_bits)
  end

  defp slice_qam(i, q, _), do: slice_qam(i, q, :qam64)

  defp qam64_axis(val) do
    cond do
      val < -0.75 -> 0
      val < -0.5 -> 1
      val < -0.25 -> 2
      val < 0.0 -> 3
      val < 0.25 -> 4
      val < 0.5 -> 5
      val < 0.75 -> 6
      true -> 7
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp reset_buffers(rx) do
    %{rx |
      symbol_buffer: [],
      iq_buffer: [],
      data_iq_buffer: [],
      sync: Sync.reset(rx.sync),
      phase_offset: nil,
      wid: nil,
      last_count: nil,
      superframes_received: 0,
      mini_probe_rx: nil,
      frames_received: 0,
      eom_scanner: EOM.scanner_new(),
      timing_offset: nil
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
