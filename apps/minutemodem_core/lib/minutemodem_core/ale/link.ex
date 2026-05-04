defmodule MinuteModemCore.ALE.Link do
  @moduledoc """
  MIL-STD-188-141D 4G ALE Link State Machine.

  Manages the lifecycle of an ALE link from idle through
  call setup, linked state, and termination.

  ## States

  - `:idle` - Not in a link, ready to call or scan
  - `:scanning` - Cycling through channel set, dwelling on each frequency
  - `:sounding` - Manual sounding run across one or more channels
  - `:lbt` - Listen Before Transmit (checking channel clear)
  - `:calling` - Sent LSU_Req, waiting for LSU_Conf
  - `:lbr` - Listen Before Respond (received LSU_Req, checking channel)
  - `:responding` - Sending LSU_Conf
  - `:linked` - Link established, ready for traffic
  - `:terminating` - Sending LSU_Term

  ## Scanning

  When scanning, the FSM cycles through the channel set synchronously:
  1. Tune to channel N (set frequency on Rig.Control + SimnetBridge)
  2. Dwell for `scan_dwell_ms` listening for capture probes
  3. If no call received, advance to channel N+1 and repeat

  When initiating a call, the caller transmits on a specified frequency
  (or the current scan channel). The called station must be scanning
  and dwelling on the same frequency to hear the call.

  ## Waveform Options

  - `:deep` - Deep WALE (240ms preamble, ~150 bps, challenging channels)
  - `:fast` - Fast WALE (120ms preamble, ~2400 bps, good channels)
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias MinuteModemCore.ALE.{PDU, Waveform, Receiver}
  alias MinuteModemCore.ALE.LQA
  alias MinuteModemCore.ALE.LQA.Sounder
  alias MinuteModemCore.Rig.Control
  alias MinuteModemCore.Rig.SimnetBridge

  # Default timing parameters (milliseconds)
  @default_timing %{
    t_lbt: 200,           # Listen before transmit duration
    t_lbr: 200,           # Listen before respond duration
    t_tune: 40,           # Radio tuning time
    t_handshake: 100,     # PDU processing + radio turnaround
    t_response: 5000,     # Wait for response (must cover remote RX + processing + remote TX + our decode)
    t_traffic: 3000,      # Wait for traffic after link setup
    t_activity: 30_000,   # Link inactivity timeout
    scan_dwell_ms: 500,   # Time to listen on each channel while scanning
    t_tx_offset: 40       # TTxOffset_TLC: delay after dwell start before transmitting (radio tuning settling)
  }

  # Default channel set for scanning when no net is configured.
  # A minimal set of commonly-used ALE frequencies.
  @default_channels [
    %{freq_hz: 7_102_000, name: "40M-ALE-1", mode: :usb},
    %{freq_hz: 7_185_000, name: "40M-ALE-2", mode: :usb},
    %{freq_hz: 14_109_000, name: "20M-ALE-1", mode: :usb},
    %{freq_hz: 14_346_000, name: "20M-ALE-2", mode: :usb}
  ]

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc """
  Start a link state machine for a rig.
  """
  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    self_addr = Keyword.fetch!(opts, :self_addr)

    GenStateMachine.start_link(
      __MODULE__,
      %{rig_id: rig_id, self_addr: self_addr, timing: @default_timing},
      name: via(rig_id)
    )
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :ale_link}}}
  end

  @doc """
  Start scanning for incoming ALE calls.

  ## Options

    * `:waveform` - `:fast` or `:deep` (default `:fast`)
    * `:channels` - List of channel maps `[%{freq_hz: ..., name: ..., mode: ...}, ...]`.
      Defaults to built-in channel set.
    * `:net_id` - Load channel set from a persisted Net definition.
    * `:scan_dwell_ms` - Override dwell time per channel.
  """
  def scan(rig_id, opts \\ []) do
    GenStateMachine.call(via(rig_id), {:scan, opts})
  end

  @doc """
  Stop scanning or cancel current operation, return to idle.
  """
  def stop(rig_id) do
    GenStateMachine.cast(via(rig_id), :stop)
  end

  @doc """
  Initiate a call to a destination address.

  ## Options

    * `:waveform` - `:fast` or `:deep` (default `:deep`)
    * `:freq_hz` - Frequency to call on. If not specified, uses
      the current scan channel (or first channel in the set).
    * `:channels` - Channel set for the call (for scanning caller pattern).
    * Other options are passed through to the PDU builder.
  """
  def call(rig_id, dest_addr, opts \\ []) do
    GenStateMachine.call(via(rig_id), {:call, dest_addr, opts})
  end

  @doc """
  Terminate the current link.
  """
  def terminate_link(rig_id, reason \\ :normal) do
    GenStateMachine.cast(via(rig_id), {:terminate, reason})
  end

  @doc """
  Initiate a manual sounding run across one or more channels.

  Pauses the current state (idle or scanning), sounds each channel
  in sequence (LBT → TX sounding → advance), then returns to the
  previous state.

  ## Options

    * `:channels` - List of channel maps to sound. If omitted, uses
      the current scan channel set (or default channels if idle).
    * `:waveform` - `:fast` or `:deep` (default: current waveform)
  """
  def sound(rig_id, opts \\ []) do
    GenStateMachine.call(via(rig_id), {:sound, opts})
  end

  @doc """
  Initiate a two-way LQA exchange with a destination station.

  This is a normal call with traffic_type = LQA Exchange. The link
  will auto-terminate after the confirm handshake.

  ## Options

    * `:waveform` - `:fast` or `:deep` (default: `:deep`)
    * `:freq_hz` - Specific frequency (optional, uses LQA ranking if omitted)
    * `:channels` - Channel set (optional)
  """
  def lqa_exchange(rig_id, dest_addr, opts \\ []) do
    exchange_opts = Sounder.exchange_call_opts(dest_addr, opts)
    GenStateMachine.call(via(rig_id), {:call, dest_addr, exchange_opts})
  end

  @doc """
  Get current link state.
  """
  def get_state(rig_id) do
    GenStateMachine.call(via(rig_id), :get_state)
  end

  @doc """
  Notify the state machine of a received PDU.
  Called by the decoder when a valid PDU is received.
  """
  def rx_pdu(rig_id, pdu) do
    GenStateMachine.cast(via(rig_id), {:rx_pdu, pdu})
  end

  @doc """
  Notify that LBT/LBR sensing is complete.
  """
  def channel_sense_complete(rig_id, result) when result in [:clear, :busy] do
    GenStateMachine.cast(via(rig_id), {:channel_sense, result})
  end

  @doc """
  Notify that the receiver has detected signal energy.
  Used by scanning to pause the dwell timer while receiving.
  """
  def signal_onset(rig_id) do
    GenStateMachine.cast(via(rig_id), :signal_onset)
  end

  @doc """
  Notify that the received signal has ended.
  Used by scanning to resume the dwell timer after receiving.
  """
  def signal_offset(rig_id) do
    GenStateMachine.cast(via(rig_id), :signal_offset)
  end

  # -------------------------------------------------------------------
  # GenStateMachine Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(data) do
    Logger.info("ALE Link starting for rig #{data.rig_id}, self_addr=0x#{Integer.to_string(data.self_addr, 16)}")

    initial_data = Map.merge(data, %{
      remote_addr: nil,
      call_opts: %{},
      link_info: nil,
      waveform: :fast,
      # Scanning state
      channels: @default_channels,
      scan_index: 0,
      scan_mode: :ale_4g,
      scan_epoch_ms: nil,       # Monotonic time when scan index 0 started
      current_freq_hz: nil,
      # Calling state — synchronous call scheduling
      call_freq_hz: nil,
      pending_call: nil,        # %{dest_addr, opts, call_freq_hz, lbt_at_ms} when waiting for call slot
      # Sounding state
      sounding_schedule: %{},   # %{freq_hz => DateTime.t()} — last sounding time per freq
      sounding_queue: [],       # [{freq_hz, symbols}, ...] — channels remaining in manual sounding run
      sounding_return_state: nil, # :idle | :scanning — state to return to after sounding completes
      soundings_this_cycle: 0,  # Counter for per-cycle sounding cap during scan
      sounding_enabled: false,  # Whether automatic scan sounding is active (from net config)
      sounding_interval_s: 300, # Minimum seconds between soundings per channel
      sounding_waveform: :deep  # Waveform used for sounding TX (from net config)
    })

    {:ok, :idle, initial_data}
  end

  # -------------------------------------------------------------------
  # State: IDLE
  # -------------------------------------------------------------------

  def idle(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering IDLE")
    broadcast_state_change(data.rig_id, :idle, nil)
    {:keep_state, %{data | remote_addr: nil, link_info: nil}}
  end

  def idle({:call, from}, {:scan, opts}, data) do
    scan_config = resolve_scan_config(opts, data)

    if scan_config.channels == [] do
      {:keep_state_and_data, [{:reply, from, {:error, :no_channels}}]}
    else
      Logger.info("ALE Link [#{data.rig_id}] starting SCAN: #{length(scan_config.channels)} channels, " <>
        "dwell=#{scan_config.scan_dwell_ms}ms, sounding_wf=#{scan_config.sounding_waveform}, mode=#{scan_config.scan_mode}, " <>
        "sounding=#{scan_config.sounding_enabled}")

      timing = %{data.timing | scan_dwell_ms: scan_config.scan_dwell_ms}

      new_data = %{data |
        waveform: scan_config.sounding_waveform,
        channels: scan_config.channels,
        scan_index: 0,
        timing: timing,
        scan_mode: scan_config.scan_mode,
        sounding_schedule: Sounder.init_schedule(data.rig_id),
        sounding_enabled: scan_config.sounding_enabled,
        sounding_interval_s: scan_config.sounding_interval_s,
        sounding_waveform: scan_config.sounding_waveform,
        soundings_this_cycle: 0
      }

      {:next_state, :scanning, new_data, [{:reply, from, :ok}]}
    end
  end

  def idle({:call, from}, {:call, dest_addr, opts}, data) do
    waveform = Keyword.get(opts, :waveform, :deep)
    scan_config = resolve_scan_config(opts, data)

    # Channel selection priority:
    # 1. Explicit :freq_hz in opts — operator override
    # 2. LQA best channel for this destination — data-driven
    # 3. Current scan channel — fallback
    call_freq = Keyword.get(opts, :freq_hz)
      || lqa_best_freq(data.rig_id, dest_addr, scan_config.channels)
      || freq_at_index(scan_config.channels, data.scan_index)

    # Per G.5.5.4: Synchronous two-way PTP link setup requires the caller
    # to be scanning synchronously with the called station. The caller
    # continues scanning until LBT time before the callee's dwell on
    # the target frequency.
    #
    # If we're idle (not scanning), we enter scanning with a pending call.
    # The scanning state will schedule the LBT jump at the right time.
    #
    # If the call frequency isn't in the channel set, fall back to
    # immediate call (async/ad-hoc mode).

    call_ch_index = find_channel_index(scan_config.channels, call_freq)

    if call_ch_index != nil and length(scan_config.channels) > 1 do
      # Synchronous mode: enter scanning with pending call
      Logger.info("ALE Link [#{data.rig_id}] sync call to 0x#{Integer.to_string(dest_addr, 16)} on #{format_freq(call_freq)} — entering scan to schedule")

      timing = %{data.timing | scan_dwell_ms: scan_config.scan_dwell_ms}

      pending = %{
        dest_addr: dest_addr,
        call_opts: Map.new(opts),
        call_freq_hz: call_freq,
        call_ch_index: call_ch_index,
        waveform: waveform,
        lbt_at_ms: nil  # Will be computed once scanning establishes an epoch
      }

      new_data = %{data |
        remote_addr: dest_addr,
        call_opts: Map.new(opts),
        call_freq_hz: call_freq,
        waveform: waveform,
        channels: scan_config.channels,
        scan_index: 0,
        scan_mode: scan_config.scan_mode,
        timing: timing,
        pending_call: pending
      }

      {:next_state, :scanning, new_data, [{:reply, from, :ok}]}
    else
      # Ad-hoc / single-channel mode: immediate call
      Logger.info("ALE Link [#{data.rig_id}] ad-hoc call to 0x#{Integer.to_string(dest_addr, 16)} on #{format_freq(call_freq)} with #{waveform}")

      new_data = %{data |
        remote_addr: dest_addr,
        call_opts: Map.new(opts),
        call_freq_hz: call_freq,
        waveform: waveform,
        channels: scan_config.channels
      }

      tune_rig(data.rig_id, call_freq)

      {:next_state, :lbt, new_data,
       [{:reply, from, :ok}, {:state_timeout, data.timing.t_tune + data.timing.t_lbt, :lbt_complete}]}
    end
  end

  def idle({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, {:idle, nil}}]}
  end

  def idle({:call, from}, {:sound, opts}, data) do
    channels = Keyword.get(opts, :channels, data.channels)
    waveform = Keyword.get(opts, :waveform, data.waveform)

    if channels == [] do
      {:keep_state_and_data, [{:reply, from, {:error, :no_channels}}]}
    else
      queue = Enum.map(channels, fn ch ->
        freq = channel_freq(ch)
        symbols = Sounder.build_sounding_frame(data.self_addr, waveform: waveform, include_probe: true)
        %{freq_hz: freq, symbols: symbols}
      end)

      Logger.info("ALE Link [#{data.rig_id}] manual sounding: #{length(queue)} channels, waveform=#{waveform}")

      new_data = %{data |
        sounding_queue: queue,
        sounding_return_state: :idle,
        waveform: waveform
      }

      {:next_state, :sounding, new_data, [{:reply, from, :ok}]}
    end
  end

  def idle(:cast, {:rx_pdu, %PDU.LsuReq{} = pdu}, data) do
    # Received a call while idle - are we the called station?
    if pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received call from 0x#{Integer.to_string(pdu.caller_addr, 16)}")

      new_data = %{data |
        remote_addr: pdu.caller_addr,
        link_info: %{
          caller_addr: pdu.caller_addr,
          called_addr: pdu.called_addr,
          voice: pdu.voice,
          traffic_type: pdu.traffic_type,
          assigned_subchannels: pdu.assigned_subchannels,
          occupied_subchannels: pdu.occupied_subchannels,
          rx_snr: nil
        }
      }

      # Stay on current frequency for LBR (we heard the call here)
      {:next_state, :lbr, new_data,
       [{:state_timeout, data.timing.t_lbr, :lbr_complete}]}
    else
      Logger.debug("ALE Link [#{data.rig_id}] ignoring call for 0x#{Integer.to_string(pdu.called_addr, 16)}")
      :keep_state_and_data
    end
  end

  def idle(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def idle(:cast, :signal_onset, _data), do: :keep_state_and_data
  def idle(:cast, :signal_offset, _data), do: :keep_state_and_data
  def idle(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data
  def idle(:cast, {:terminate, _reason}, _data), do: :keep_state_and_data
  def idle(:cast, :stop, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: SCANNING
  #
  # Synchronous frequency-hopping scan. On entry (and on each dwell
  # timeout), we tune to the next channel in the set and listen for
  # scan_dwell_ms before advancing.
  # -------------------------------------------------------------------

  def scanning(:enter, _old_state, data) do
    Logger.info("ALE Link [#{data.rig_id}] entering SCANNING")

    dwell_ms = data.timing.scan_dwell_ms
    n_channels = length(data.channels)
    cycle_len = n_channels * dwell_ms

    # Synchronous scanning: align to wall clock so all stations on the
    # same net are in lockstep. The epoch is the most recent cycle
    # boundary in wall-clock time. Since all stations use the same
    # clock reference and the same cycle_len, they compute the same
    # channel index at any given moment.
    now_wall = System.os_time(:millisecond)
    epoch = now_wall - rem(now_wall, cycle_len)

    # Compute which channel index we should be on right now
    ms_into_cycle = now_wall - epoch
    current_index = min(div(ms_into_cycle, dwell_ms), n_channels - 1)
    ms_into_dwell = ms_into_cycle - current_index * dwell_ms
    remaining_dwell = max(dwell_ms - ms_into_dwell, 1)

    # Tune to the correct channel
    channel = Enum.at(data.channels, current_index)
    freq = channel_freq(channel)
    tune_rig(data.rig_id, freq)

    Logger.info("ALE Link [#{data.rig_id}] scan: synced to #{channel_name(channel)} (#{format_freq(freq)}), index=#{current_index}/#{n_channels}, #{remaining_dwell}ms left in dwell")
    broadcast_state_change(data.rig_id, :scanning, %{
      waveform: data.waveform,
      scan_mode: data.scan_mode,
      scan_dwell_ms: dwell_ms,
      channel: channel,
      index: current_index,
      num_channels: n_channels,
      freq_hz: freq,
      pending_call: data.pending_call != nil
    })

    # If there's a pending call without a computed lbt_at_ms (came from idle),
    # compute it now that we have an epoch.
    now_mono = System.monotonic_time(:millisecond)
    updated_pending = case data.pending_call do
      %{lbt_at_ms: nil, call_ch_index: call_ch_index} = pending ->
        lbt_at = compute_lbt_time(epoch, call_ch_index, data.timing, n_channels, now_wall, now_mono)
        Logger.info("ALE Link [#{data.rig_id}] sync call scheduled: LBT in #{lbt_at - now_mono}ms for ch #{call_ch_index}")
        %{pending | lbt_at_ms: lbt_at}

      other ->
        other
    end

    new_data = %{data |
      current_freq_hz: freq,
      scan_epoch_ms: epoch,
      scan_index: current_index,
      pending_call: updated_pending
    }

    # Start the dwell timer for the remaining time in the current dwell slot
    {:keep_state, new_data, [{:state_timeout, remaining_dwell, :dwell_timeout}]}
  end

  # Dwell timer expired — advance to next channel, or jump to LBT if pending call is due
  def scanning(:state_timeout, :dwell_timeout, data) do
    now_mono = System.monotonic_time(:millisecond)

    # Check if a pending synchronous call is due
    case data.pending_call do
      %{lbt_at_ms: lbt_at} = pending when is_integer(lbt_at) and now_mono >= lbt_at ->
        # Time to jump to the call frequency and begin LBT
        Logger.info("ALE Link [#{data.rig_id}] sync call: jumping to #{format_freq(pending.call_freq_hz)} for LBT")

        new_data = %{data |
          remote_addr: pending.dest_addr,
          call_opts: pending.call_opts,
          call_freq_hz: pending.call_freq_hz,
          waveform: pending.waveform,
          pending_call: nil
        }

        tune_rig(data.rig_id, pending.call_freq_hz)

        {:next_state, :lbt, new_data,
         [{:state_timeout, data.timing.t_tune + data.timing.t_lbt, :lbt_complete}]}

      _ ->
        # Normal scan hop
        # Recompute from wall clock to stay synchronized
        dwell_ms = data.timing.scan_dwell_ms
        n_channels = length(data.channels)
        cycle_len = n_channels * dwell_ms

        now_wall = System.os_time(:millisecond)
        ms_into_cycle = rem(now_wall - data.scan_epoch_ms, cycle_len)
        next_index = min(div(ms_into_cycle, dwell_ms), n_channels - 1)
        ms_into_dwell = ms_into_cycle - next_index * dwell_ms
        remaining_dwell = max(dwell_ms - ms_into_dwell, 1)

        channel = Enum.at(data.channels, next_index)
        freq = channel_freq(channel)

        Logger.info("ALE Link [#{data.rig_id}] scan: hop to #{channel_name(channel)} (#{format_freq(freq)}), index=#{next_index}/#{n_channels}")

        tune_rig(data.rig_id, freq)
        broadcast_state_change(data.rig_id, :scanning, %{
          waveform: data.waveform,
          scan_mode: data.scan_mode,
          scan_dwell_ms: dwell_ms,
          channel: channel,
          index: next_index,
          num_channels: n_channels,
          freq_hz: freq,
          pending_call: data.pending_call != nil
        })

        # Reset soundings_this_cycle when we wrap around to index 0
        soundings_count = if next_index == 0, do: 0, else: data.soundings_this_cycle

        updated_data = %{data |
          scan_index: next_index,
          current_freq_hz: freq,
          soundings_this_cycle: soundings_count
        }

        # Schedule a sounding early in this dwell if needed.
        # Use address-based stagger: offset = (self_addr * 137 mod dwell) clamped
        # to first half of dwell, so TX completes before dwell ends.
        updated_data = maybe_schedule_sounding(updated_data, remaining_dwell)

        {:keep_state, updated_data, [{:state_timeout, remaining_dwell, :dwell_timeout}]}
    end
  end

  def scanning({:call, from}, :get_state, data) do
    channel = Enum.at(data.channels, data.scan_index)
    info = %{
      waveform: data.waveform,
      scan_mode: data.scan_mode,
      channel: channel,
      index: data.scan_index,
      freq_hz: data.current_freq_hz,
      scan_dwell_ms: data.timing.scan_dwell_ms,
      num_channels: length(data.channels),
      pending_call: data.pending_call != nil
    }
    {:keep_state_and_data, [{:reply, from, {:scanning, info}}]}
  end

  def scanning({:call, from}, {:call, dest_addr, opts}, data) do
    # Synchronous two-way PTP call (G.5.5.4).
    #
    # The caller must time the LSU_Req to arrive during the callee's dwell
    # on the target frequency. Since both stations scan the same channel set
    # synchronously, we can compute when to jump.
    #
    # Channel selection: explicit freq > LQA best > current scan channel.
    waveform = Keyword.get(opts, :waveform, :deep)
    call_freq = Keyword.get(opts, :freq_hz)
      || lqa_best_freq(data.rig_id, dest_addr, data.channels)
      || data.current_freq_hz

    # Find the channel index for the call frequency
    call_ch_index = find_channel_index(data.channels, call_freq)

    if call_ch_index == nil do
      Logger.warning("ALE Link [#{data.rig_id}] call freq #{format_freq(call_freq)} not in channel set")
      {:keep_state_and_data, [{:reply, from, {:error, :freq_not_in_channel_set}}]}
    else
      now_wall = System.os_time(:millisecond)
      now_mono = System.monotonic_time(:millisecond)
      lbt_at = compute_lbt_time(data.scan_epoch_ms, call_ch_index, data.timing, length(data.channels), now_wall, now_mono)
      time_until_lbt = lbt_at - now_mono

      if time_until_lbt <= 0 do
        # We're already in or past the LBT window — go immediately.
        Logger.info("ALE Link [#{data.rig_id}] sync call: immediate LBT on #{format_freq(call_freq)}")

        new_data = %{data |
          remote_addr: dest_addr,
          call_opts: Map.new(opts),
          call_freq_hz: call_freq,
          waveform: waveform,
          pending_call: nil
        }

        tune_rig(data.rig_id, call_freq)

        {:next_state, :lbt, new_data,
         [{:reply, from, :ok},
          {:state_timeout, data.timing.t_tune + data.timing.t_lbt, :lbt_complete}]}
      else
        # Schedule the call — continue scanning until it's time to jump.
        Logger.info("ALE Link [#{data.rig_id}] sync call: scheduling call to " <>
          "0x#{Integer.to_string(dest_addr, 16)} on #{format_freq(call_freq)} (ch #{call_ch_index}), " <>
          "LBT in #{time_until_lbt}ms")

        pending = %{
          dest_addr: dest_addr,
          call_opts: Map.new(opts),
          call_freq_hz: call_freq,
          call_ch_index: call_ch_index,
          waveform: waveform,
          lbt_at_ms: lbt_at
        }

        new_data = %{data | pending_call: pending}

        # Continue scanning — the dwell timeout handler will check pending_call
        {:keep_state, new_data, [{:reply, from, :ok}]}
      end
    end
  end

  def scanning({:call, from}, {:scan, _opts}, _data) do
    # Already scanning
    {:keep_state_and_data, [{:reply, from, {:error, :already_scanning}}]}
  end

  def scanning(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] stopping scan")
    {:next_state, :idle, %{data | pending_call: nil}}
  end

  def scanning(:cast, {:rx_pdu, %PDU.LsuReq{} = pdu}, data) do
    # Received a call while scanning
    if pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received call while scanning on #{format_freq(data.current_freq_hz)} from 0x#{Integer.to_string(pdu.caller_addr, 16)}")

      new_data = %{data |
        remote_addr: pdu.caller_addr,
        # Stay on current frequency — we heard the call here
        call_freq_hz: data.current_freq_hz,
        link_info: %{
          caller_addr: pdu.caller_addr,
          called_addr: pdu.called_addr,
          voice: pdu.voice,
          traffic_type: pdu.traffic_type,
          assigned_subchannels: pdu.assigned_subchannels,
          occupied_subchannels: pdu.occupied_subchannels,
          rx_snr: nil,
          freq_hz: data.current_freq_hz
        }
      }

      {:next_state, :lbr, new_data,
       [{:state_timeout, data.timing.t_lbr, :lbr_complete}]}
    else
      :keep_state_and_data
    end
  end

  def scanning(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data

  def scanning({:call, from}, {:sound, opts}, data) do
    channels = Keyword.get(opts, :channels, data.channels)
    waveform = Keyword.get(opts, :waveform, data.waveform)

    if channels == [] do
      {:keep_state_and_data, [{:reply, from, {:error, :no_channels}}]}
    else
      queue = Enum.map(channels, fn ch ->
        freq = channel_freq(ch)
        symbols = Sounder.build_sounding_frame(data.self_addr, waveform: waveform, include_probe: true)
        %{freq_hz: freq, symbols: symbols}
      end)

      Logger.info("ALE Link [#{data.rig_id}] manual sounding from scan: #{length(queue)} channels")

      new_data = %{data |
        sounding_queue: queue,
        sounding_return_state: :scanning,
        waveform: waveform,
        pending_call: nil  # Cancel pending call — sounding takes priority
      }

      {:next_state, :sounding, new_data, [{:reply, from, :ok}]}
    end
  end

  # Sounding timer fired — transmit if we're still on the expected channel.
  def scanning(:info, {:sounding_fire, expected_freq}, data) do
    if data.current_freq_hz == expected_freq and not Map.get(data, :rx_hold, false) do
      if Receiver.channel_busy?(data.rig_id) do
        Logger.info("ALE Link [#{data.rig_id}] sounding skipped: channel busy on #{format_freq(expected_freq)}")
        :keep_state_and_data
      else
        Logger.info("ALE Link [#{data.rig_id}] sounding TX on #{format_freq(expected_freq)}")
        # Always use async=true: include capture probe + TLC for reliable decode
        new_data = do_sounding_tx(data, expected_freq, true)
        {:keep_state, new_data}
      end
    else
      # We've moved off this channel or are receiving — skip
      :keep_state_and_data
    end
  end

  # Signal onset — freeze the scanner on this channel while receiving.
  # Cancel the dwell timer by setting an infinite timeout (we'll restart
  # it on signal_offset). Also set a safety timeout so we don't freeze
  # forever if the receiver never fires signal_offset.
  @max_rx_hold_ms 15_000

  def scanning(:cast, :signal_onset, data) do
    Logger.info("ALE Link [#{data.rig_id}] scan: signal detected on #{format_freq(data.current_freq_hz)}, holding channel")
    {:keep_state, Map.put(data, :rx_hold, true), [{:state_timeout, @max_rx_hold_ms, :dwell_timeout}]}
  end

  # Signal offset — resume normal dwell timing.
  def scanning(:cast, :signal_offset, data) do
    Logger.info("ALE Link [#{data.rig_id}] scan: signal ended on #{format_freq(data.current_freq_hz)}, resuming scan")
    # Give a short grace period for decode + rx_pdu delivery before hopping
    {:keep_state, Map.delete(data, :rx_hold), [{:state_timeout, 200, :dwell_timeout}]}
  end

  # Catch-all for scanning state — log anything unexpected
  def scanning(event_type, event_content, data) do
    Logger.info("ALE Link [#{data.rig_id}] scanning: unhandled #{inspect(event_type)} #{inspect(event_content)}")
    :keep_state_and_data
  end

  # -------------------------------------------------------------------
  # State: SOUNDING
  #
  # Manual sounding run. Iterates through sounding_queue:
  # tune → LBT → TX sounding → record → advance to next channel.
  # On completion, returns to sounding_return_state.
  #
  # Per G.5.5.10.1: LBT before sounding, skip channel if busy.
  # -------------------------------------------------------------------

  def sounding(:enter, _old_state, data) do
    Logger.info("ALE Link [#{data.rig_id}] entering SOUNDING: #{length(data.sounding_queue)} channels queued")
    broadcast_state_change(data.rig_id, :sounding, %{
      remaining: length(data.sounding_queue),
      total: length(data.sounding_queue)
    })

    # Immediately start processing the first channel
    {:keep_state_and_data, [{:state_timeout, 0, :sounding_next}]}
  end

  def sounding(:state_timeout, :sounding_next, %{sounding_queue: []} = data) do
    # Queue exhausted — return to previous state
    Logger.info("ALE Link [#{data.rig_id}] sounding complete, returning to #{data.sounding_return_state}")
    broadcast_event(data.rig_id, :sounding_complete, %{})

    case data.sounding_return_state do
      :scanning ->
        {:next_state, :scanning, %{data | sounding_queue: [], sounding_return_state: nil}}
      _ ->
        {:next_state, :idle, %{data | sounding_queue: [], sounding_return_state: nil}}
    end
  end

  def sounding(:state_timeout, :sounding_next, data) do
    [current | rest] = data.sounding_queue

    Logger.info("ALE Link [#{data.rig_id}] sounding: tuning to #{format_freq(current.freq_hz)}, #{length(rest)} remaining")

    # Tune to the target frequency
    tune_rig(data.rig_id, current.freq_hz)

    new_data = %{data |
      current_freq_hz: current.freq_hz,
      sounding_queue: rest
    }

    broadcast_state_change(data.rig_id, :sounding, %{
      freq_hz: current.freq_hz,
      remaining: length(rest),
      total: length(rest) + 1
    })

    # LBT: wait for tune + LBT duration, then transmit
    lbt_duration = data.timing.t_tune + data.timing.t_lbt
    {:keep_state, new_data, [{:state_timeout, lbt_duration, {:sounding_lbt_complete, current}}]}
  end

  def sounding(:state_timeout, {:sounding_lbt_complete, current}, data) do
    # LBT complete — transmit the sounding frame
    # (In a real implementation, we'd check channel_sense here.
    #  For now, we transmit unconditionally and note the TODO.)
    Logger.info("ALE Link [#{data.rig_id}] sounding: TX on #{format_freq(current.freq_hz)}")

    transmit_frame(data.rig_id, current.symbols)

    # Record in the sounding schedule
    new_schedule = Sounder.record_sounding_tx(data.sounding_schedule, current.freq_hz)

    # Persist the TX sounding to the LQA database
    try do
      alias MinuteModemCore.Persistence.Callsigns
      Callsigns.record_sounding(data.self_addr, current.freq_hz,
        rig_id: data.rig_id,
        direction: "tx",
        frame_type: "sounding",
        source: "sounding"
      )
    rescue
      e -> Logger.warning("ALE Link [#{data.rig_id}] sounding DB write failed: #{inspect(e)}")
    end

    new_data = %{data | sounding_schedule: new_schedule}

    # Brief pause for TX to complete, then advance to next channel
    # Estimate TX duration from frame length
    tx_duration_ms = div(length(current.symbols) * 1000, 4800) + 50
    {:keep_state, new_data, [{:state_timeout, tx_duration_ms, :sounding_next}]}
  end

  def sounding({:call, from}, :get_state, data) do
    info = %{
      remaining: length(data.sounding_queue),
      freq_hz: data.current_freq_hz,
      return_state: data.sounding_return_state
    }
    {:keep_state_and_data, [{:reply, from, {:sounding, info}}]}
  end

  def sounding(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] sounding interrupted by stop")
    broadcast_event(data.rig_id, :sounding_interrupted, %{remaining: length(data.sounding_queue)})
    {:next_state, :idle, %{data | sounding_queue: [], sounding_return_state: nil}}
  end

  def sounding(:cast, {:rx_pdu, %PDU.LsuReq{} = pdu}, data) do
    # Received a call during sounding — if it's for us, abort sounding and respond
    if pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received call during sounding, aborting to respond")

      new_data = %{data |
        remote_addr: pdu.caller_addr,
        call_freq_hz: data.current_freq_hz,
        sounding_queue: [],
        sounding_return_state: nil,
        link_info: %{
          caller_addr: pdu.caller_addr,
          called_addr: pdu.called_addr,
          voice: pdu.voice,
          traffic_type: pdu.traffic_type,
          assigned_subchannels: pdu.assigned_subchannels,
          occupied_subchannels: pdu.occupied_subchannels,
          rx_snr: nil,
          freq_hz: data.current_freq_hz
        }
      }

      {:next_state, :lbr, new_data,
       [{:state_timeout, data.timing.t_lbr, :lbr_complete}]}
    else
      :keep_state_and_data
    end
  end

  def sounding(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def sounding(:cast, :signal_onset, _data), do: :keep_state_and_data
  def sounding(:cast, :signal_offset, _data), do: :keep_state_and_data
  def sounding(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  def sounding({:call, from}, {:call, _dest_addr, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sounding_in_progress}}]}
  end

  def sounding({:call, from}, {:scan, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sounding_in_progress}}]}
  end

  def sounding({:call, from}, {:sound, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sounding_in_progress}}]}
  end

  # -------------------------------------------------------------------
  # State: LBT (Listen Before Transmit)
  # -------------------------------------------------------------------

  def lbt(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering LBT on #{format_freq(data.call_freq_hz)}")
    broadcast_state_change(data.rig_id, :lbt, %{remote_addr: data.remote_addr, freq_hz: data.call_freq_hz})
    :keep_state_and_data
  end

  def lbt(:state_timeout, :lbt_complete, data) do
    Logger.debug("ALE Link [#{data.rig_id}] LBT complete, channel clear")
    {:next_state, :calling, data}
  end

  def lbt(:cast, {:channel_sense, :busy}, data) do
    Logger.warning("ALE Link [#{data.rig_id}] channel busy during LBT")
    broadcast_event(data.rig_id, :call_failed, :channel_busy)
    {:next_state, :idle, data}
  end

  def lbt({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:lbt, data.remote_addr}}]}
  end

  def lbt(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled during LBT")
    {:next_state, :idle, data}
  end

  def lbt(:cast, {:terminate, _reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled during LBT")
    {:next_state, :idle, data}
  end

  # Absorb PDUs during LBT (we're about to TX)
  def lbt(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def lbt(:cast, :signal_onset, _data), do: :keep_state_and_data
  def lbt(:cast, :signal_offset, _data), do: :keep_state_and_data
  def lbt(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: CALLING
  # -------------------------------------------------------------------

  def calling(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering CALLING")
    broadcast_state_change(data.rig_id, :calling, %{remote_addr: data.remote_addr, freq_hz: data.call_freq_hz})

    # Ensure we're on the call frequency
    tune_rig(data.rig_id, data.call_freq_hz)

    # Build and transmit LSU_Req using selected waveform
    waveform = Map.get(data.call_opts, :waveform, data.waveform)
    tuner_time_ms = Map.get(data.call_opts, :tuner_time_ms, 50)
    Logger.info("ALE Link [#{data.rig_id}] calling: waveform=#{waveform}, freq=#{format_freq(data.call_freq_hz)}, tuner_time_ms=#{tuner_time_ms}")

    pdu = %PDU.LsuReq{
      caller_addr: data.self_addr,
      called_addr: data.remote_addr,
      voice: Map.get(data.call_opts, :voice, false),
      traffic_type: Map.get(data.call_opts, :traffic_type, 0),
      assigned_subchannels: Map.get(data.call_opts, :assigned_subchannels, 0xFFFF),
      occupied_subchannels: Map.get(data.call_opts, :occupied_subchannels, 0)
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      include_probe: true,
      tuner_time_ms: tuner_time_ms,
      capture_probe_count: 1,
      preamble_count: 1
    )

    Logger.info("ALE Link [#{data.rig_id}] LsuReq frame: pdu=#{byte_size(pdu_binary)} bytes, symbols=#{length(symbols)}")

    # Send to modulator
    transmit_frame(data.rig_id, symbols)

    # Calculate TX duration and set response timeout
    timing = Waveform.frame_timing(pdu_binary, waveform: waveform, tuner_time_ms: tuner_time_ms)
    response_timeout = round(timing.duration_ms) + data.timing.t_response

    {:keep_state_and_data, [{:state_timeout, response_timeout, :response_timeout}]}
  end

  def calling(:state_timeout, :response_timeout, data) do
    Logger.warning("ALE Link [#{data.rig_id}] no response from 0x#{Integer.to_string(data.remote_addr, 16)}")

    send_terminate(data, PDU.LsuTerm.reason_timeout())

    broadcast_event(data.rig_id, :call_failed, :no_response)
    {:next_state, :idle, data}
  end

  def calling(:cast, {:rx_pdu, %PDU.LsuConf{} = pdu}, data) do
    if pdu.caller_addr == data.self_addr and pdu.called_addr == data.remote_addr do
      Logger.info("ALE Link [#{data.rig_id}] received confirm from 0x#{Integer.to_string(data.remote_addr, 16)}")

      link_info = %{
        caller_addr: data.self_addr,
        called_addr: data.remote_addr,
        voice: pdu.voice,
        snr: pdu.snr,
        tx_subchannels: pdu.tx_subchannels,
        rx_subchannels: pdu.rx_subchannels,
        we_are: :caller,
        freq_hz: data.call_freq_hz
      }

      new_data = %{data | link_info: link_info, current_freq_hz: data.call_freq_hz}
      {:next_state, :linked, new_data}
    else
      :keep_state_and_data
    end
  end

  def calling(:cast, {:rx_pdu, %PDU.LsuTerm{} = pdu}, data) do
    if pdu.called_addr == data.self_addr or pdu.caller_addr == data.remote_addr do
      Logger.info("ALE Link [#{data.rig_id}] call rejected, reason=#{pdu.reason}")
      broadcast_event(data.rig_id, :call_failed, {:rejected, pdu.reason})
      {:next_state, :idle, data}
    else
      :keep_state_and_data
    end
  end

  def calling({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:calling, data.remote_addr}}]}
  end

  def calling(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled by user")
    send_terminate(data, reason_to_code(:normal))
    {:next_state, :idle, data}
  end

  def calling(:cast, {:terminate, reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled by user")
    send_terminate(data, reason_to_code(reason))
    {:next_state, :idle, data}
  end

  def calling(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def calling(:cast, :signal_onset, _data), do: :keep_state_and_data
  def calling(:cast, :signal_offset, _data), do: :keep_state_and_data
  def calling(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: LBR (Listen Before Respond)
  # -------------------------------------------------------------------

  def lbr(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering LBR on #{format_freq(data.current_freq_hz)}")
    broadcast_state_change(data.rig_id, :lbr, %{remote_addr: data.remote_addr, freq_hz: data.current_freq_hz})
    :keep_state_and_data
  end

  def lbr(:state_timeout, :lbr_complete, data) do
    Logger.debug("ALE Link [#{data.rig_id}] LBR complete, responding")
    {:next_state, :responding, data}
  end

  def lbr(:cast, {:channel_sense, :busy}, data) do
    Logger.warning("ALE Link [#{data.rig_id}] channel busy during LBR, not responding")
    broadcast_event(data.rig_id, :incoming_call_dropped, :channel_busy)
    {:next_state, :idle, data}
  end

  def lbr({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:lbr, data.remote_addr}}]}
  end

  def lbr(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] response cancelled")
    {:next_state, :idle, data}
  end

  def lbr(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def lbr(:cast, :signal_onset, _data), do: :keep_state_and_data
  def lbr(:cast, :signal_offset, _data), do: :keep_state_and_data
  def lbr(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: RESPONDING
  # -------------------------------------------------------------------

  def responding(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering RESPONDING on #{format_freq(data.current_freq_hz)}")
    broadcast_state_change(data.rig_id, :responding, %{remote_addr: data.remote_addr, freq_hz: data.current_freq_hz})

    t_confirm = data.timing.t_tune + data.timing.t_handshake
    {:keep_state_and_data, [{:state_timeout, t_confirm, :send_confirm}]}
  end

  def responding(:state_timeout, :send_confirm, data) do
    # Respond on the same frequency we heard the call on
    pdu = %PDU.LsuConf{
      caller_addr: data.link_info.caller_addr,
      called_addr: data.self_addr,
      voice: data.link_info.voice,
      snr: data.link_info[:rx_snr] || 0,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: data.waveform,
      include_probe: true,
      tuner_time_ms: data.timing.t_tune
    )

    Logger.info("ALE Link [#{data.rig_id}] LsuConf frame: pdu=#{byte_size(pdu_binary)} bytes, symbols=#{length(symbols)}")

    transmit_frame(data.rig_id, symbols)

    link_info = Map.merge(data.link_info, %{
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF,
      we_are: :responder,
      freq_hz: data.current_freq_hz
    })

    new_data = %{data | link_info: link_info}
    {:next_state, :linked, new_data}
  end

  def responding({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:responding, data.remote_addr}}]}
  end

  def responding(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] response cancelled")
    {:next_state, :idle, data}
  end

  def responding(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def responding(:cast, :signal_onset, _data), do: :keep_state_and_data
  def responding(:cast, :signal_offset, _data), do: :keep_state_and_data
  def responding(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: LINKED
  # -------------------------------------------------------------------

  def linked(:enter, _old_state, data) do
    freq = data.current_freq_hz || Map.get(data.link_info || %{}, :freq_hz)
    Logger.info("ALE Link [#{data.rig_id}] LINKED with 0x#{Integer.to_string(data.remote_addr, 16)} on #{format_freq(freq)}")
    broadcast_state_change(data.rig_id, :linked, data.link_info)

    # Auto-terminate LQA exchange links (G.5.5.10.2)
    # If we initiated an LQA exchange, terminate immediately after link is established.
    traffic_type = get_in(data, [:call_opts, :traffic_type]) || get_in(data, [:link_info, :traffic_type])
    if traffic_type == Sounder.traffic_type_lqa_exchange() do
      # Wait for the LsuConf frame to finish playing out before sending LsuTerm.
      # The LsuConf was just queued to the audio pipeline but hasn't finished TX yet.
      # Deep WALE ~2885ms, Fast WALE ~400ms
      conf_tx_ms = if data.waveform == :deep, do: 3000, else: 500
      delay_ms = conf_tx_ms + 500
      Logger.info("ALE Link [#{data.rig_id}] LQA exchange complete, auto-terminating in #{delay_ms}ms")
      {:keep_state_and_data, [{:state_timeout, delay_ms, :lqa_exchange_terminate}]}
    else
      {:keep_state_and_data, [{:state_timeout, data.timing.t_activity, :activity_timeout}]}
    end
  end

  def linked(:state_timeout, :lqa_exchange_terminate, data) do
    send_terminate(data, Sounder.reason_no_more_traffic())
    broadcast_event(data.rig_id, :lqa_exchange_complete, %{remote_addr: data.remote_addr})
    {:next_state, :idle, data}
  end

  def linked(:state_timeout, :activity_timeout, data) do
    Logger.warning("ALE Link [#{data.rig_id}] activity timeout, terminating")
    send_terminate(data, PDU.LsuTerm.reason_timeout())
    {:next_state, :idle, data}
  end

  def linked(:cast, {:rx_pdu, %PDU.LsuTerm{} = pdu}, data) do
    if pdu.caller_addr == data.remote_addr or pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received terminate, reason=#{pdu.reason}")
      broadcast_event(data.rig_id, :link_terminated, {:remote, pdu.reason})
      {:next_state, :idle, data}
    else
      :keep_state_and_data
    end
  end

  def linked(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] terminating link")
    send_terminate(data, reason_to_code(:normal))
    broadcast_event(data.rig_id, :link_terminated, {:local, :normal})
    {:next_state, :idle, data}
  end

  def linked(:cast, {:terminate, reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] terminating link, reason=#{reason}")
    send_terminate(data, reason_to_code(reason))
    broadcast_event(data.rig_id, :link_terminated, {:local, reason})
    {:next_state, :idle, data}
  end

  def linked(:cast, :activity, data) do
    {:keep_state_and_data, [{:state_timeout, data.timing.t_activity, :activity_timeout}]}
  end

  def linked({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:linked, data.link_info}}]}
  end

  def linked({:call, from}, {:call, _dest_addr, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_linked}}]}
  end

  def linked(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def linked(:cast, :signal_onset, _data), do: :keep_state_and_data
  def linked(:cast, :signal_offset, _data), do: :keep_state_and_data
  def linked(:info, {:sounding_fire, _}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # Rig Control — frequency tuning
  # -------------------------------------------------------------------

  defp tune_rig(rig_id, nil) do
    Logger.debug("ALE Link [#{rig_id}] tune_rig: no frequency, skipping")
    :ok
  end

  defp tune_rig(rig_id, freq_hz) do
    # Set frequency on Rig.Control (drives rigctld for physical rigs,
    # no-op for test/simulator backends)
    case safe_call(fn -> Control.set_frequency(rig_id, freq_hz) end) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("ALE Link [#{rig_id}] Control.set_frequency failed: #{inspect(reason)}")
    end

    # Set RX frequency on SimnetBridge (for test/simulator rigs,
    # this tunes the simnet combiner's frequency filter)
    case safe_call(fn -> SimnetBridge.set_frequency(rig_id, freq_hz) end) do
      :ok -> :ok
      _ -> :ok  # SimnetBridge may not be running for physical rigs
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp transmit_frame(rig_id, symbols) do
    Logger.debug("ALE Link [#{rig_id}] TX frame: #{length(symbols)} symbols")

    # First, broadcast the symbols so test harnesses can intercept
    broadcast(rig_id, {:ale_tx_symbols, rig_id, symbols})

    # Then try the actual Transmitter (if running)
    try do
      case MinuteModemCore.ALE.Transmitter.transmit(rig_id, symbols) do
        :ok ->
          broadcast_event(rig_id, :tx_complete, %{symbols: length(symbols)})
          :ok

        {:error, reason} ->
          Logger.error("ALE Link [#{rig_id}] TX failed: #{inspect(reason)}")
          broadcast_event(rig_id, :tx_failed, reason)
          {:error, reason}
      end
    catch
      :exit, {:noproc, _} ->
        # Transmitter not running - that's OK for testing
        Logger.debug("ALE Link [#{rig_id}] Transmitter not running, symbols broadcast only")
        broadcast_event(rig_id, :tx_complete, %{symbols: length(symbols), simulated: true})
        :ok

      :exit, reason ->
        Logger.error("ALE Link [#{rig_id}] TX error: #{inspect(reason)}")
        broadcast_event(rig_id, :tx_failed, reason)
        {:error, reason}
    end
  end

  defp send_terminate(data, reason_code) do
    pdu = %PDU.LsuTerm{
      caller_addr: data.self_addr,
      called_addr: data.remote_addr,
      reason: reason_code
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: data.waveform,
      include_probe: true,
      tuner_time_ms: data.timing.t_tune
    )

    Logger.info("ALE Link [#{data.rig_id}] LsuTerm frame: pdu=#{byte_size(pdu_binary)} bytes, symbols=#{length(symbols)}")

    transmit_frame(data.rig_id, symbols)
  end

  defp reason_to_code(:normal), do: PDU.LsuTerm.reason_normal()
  defp reason_to_code(:timeout), do: PDU.LsuTerm.reason_timeout()
  defp reason_to_code(:busy), do: PDU.LsuTerm.reason_busy()
  defp reason_to_code(:channel_busy), do: PDU.LsuTerm.reason_channel_busy()
  defp reason_to_code(_), do: PDU.LsuTerm.reason_normal()

  # --- LQA-informed channel selection ---

  # Query the LQA database for the best channel to reach a destination.
  # Returns a freq_hz or nil if no LQA data exists.
  defp lqa_best_freq(rig_id, dest_addr, channels) do
    case LQA.best_channel(rig_id, dest_addr, channels) do
      %{freq_hz: freq, score: score} when score > 0 ->
        Logger.info("ALE Link [#{rig_id}] LQA selected #{format_freq(freq)} (score=#{score}) for 0x#{Integer.to_string(dest_addr, 16)}")
        freq
      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("ALE Link [#{rig_id}] LQA query failed: #{inspect(e)}")
      nil
  end

  # --- Inline sounding during scan ---

  # Determine if we're in a synchronous multi-channel scan.
  # Sync: wall-clock-aligned scan across multiple channels — all stations
  # on the same net dwell on the same channel simultaneously.
  # Async: single-channel, ad-hoc, or free-running scan.
  defp sync_scan?(data) do
    length(data.channels) > 1 and data.scan_mode in [:ale_4g, :ale_3g]
  end

  # Schedule a sounding early in the dwell if conditions are met.
  # Uses address-based stagger to avoid collisions between stations.
  defp maybe_schedule_sounding(%{sounding_enabled: false} = data, _remaining_dwell), do: data
  defp maybe_schedule_sounding(%{current_freq_hz: nil} = data, _remaining_dwell), do: data
  defp maybe_schedule_sounding(data, remaining_dwell) do
    should = Sounder.should_sound?(
      data.sounding_schedule,
      data.current_freq_hz,
      min_interval_s: data.sounding_interval_s,
      soundings_this_cycle: data.soundings_this_cycle,
      max_per_cycle: length(data.channels)
    )

    if should do
      # Random delay within [200, remaining_dwell - 3000] to spread soundings.
      # Each process has its own :rand PRNG state (seeded automatically by OTP),
      # so no coordination needed — collisions are probabilistic, not systematic.
      max_delay = max(div(remaining_dwell, 2), 300)
      delay_ms = 200 + :rand.uniform(max_delay - 200)

      if delay_ms + 3000 < remaining_dwell do
        # Enough room for the sounding frame within this dwell
        Logger.info("ALE Link [#{data.rig_id}] sounding scheduled in #{delay_ms}ms on #{format_freq(data.current_freq_hz)}")
        Process.send_after(self(), {:sounding_fire, data.current_freq_hz}, delay_ms)
        data
      else
        data
      end
    else
      data
    end
  end

  # Check if we should sound before leaving the current channel.
  # Dispatches to sync or async path based on scan mode.
  defp maybe_sound_inline(%{sounding_enabled: false} = data), do: data
  defp maybe_sound_inline(%{current_freq_hz: nil} = data), do: data
  defp maybe_sound_inline(data) do
    if sync_scan?(data) do
      maybe_sound_sync(data)
    else
      maybe_sound_async(data)
    end
  end

  # --- Sync mode: sound on the current dwell channel ---
  #
  # Per G.5.5.10.1(b): "When a network is scanning synchronously, the
  # sound shall be sent when the network is dwelling on that channel."
  # No capture probe needed — everyone is already listening.
  defp maybe_sound_sync(data) do
    should = Sounder.should_sound?(
      data.sounding_schedule,
      data.current_freq_hz,
      min_interval_s: data.sounding_interval_s,
      soundings_this_cycle: data.soundings_this_cycle,
      max_per_cycle: length(data.channels)
    )

    if should do
      # LBT: check receiver for energy on this channel (G.5.5.10.1(a))
      if Receiver.channel_busy?(data.rig_id) do
        Logger.debug("ALE Link [#{data.rig_id}] sync sounding skipped: channel busy on #{format_freq(data.current_freq_hz)}")
        data
      else
        Logger.info("ALE Link [#{data.rig_id}] sync sounding on #{format_freq(data.current_freq_hz)}")
        do_sounding_tx(data, data.current_freq_hz, _async = false)
      end
    else
      data
    end
  end

  # --- Async mode: detour to the stalest channel ---
  #
  # Per G.5.5.10.1(c): "An asynchronous sound begins with a capture
  # probe, followed by the LSU_Status PDU."
  # We tune away from the current scan channel, sound, and return.
  defp maybe_sound_async(data) do
    case Sounder.next_sounding_target(data.sounding_schedule, data.channels,
           stale_threshold_s: data.sounding_interval_s) do
      nil ->
        # All channels are fresh — nothing to do
        data

      {target_freq, _priority} ->
        # Check per-cycle cap
        if data.soundings_this_cycle >= length(data.channels) do
          data
        else
          Logger.info("ALE Link [#{data.rig_id}] async sounding detour to #{format_freq(target_freq)}")

          # Tune to target
          tune_rig(data.rig_id, target_freq)

          # LBT: check receiver for energy after tuning
          # Brief pause to let receiver settle on new frequency
          Process.sleep(div(data.timing.t_lbt, 2))

          if Receiver.channel_busy?(data.rig_id) do
            Logger.debug("ALE Link [#{data.rig_id}] async sounding skipped: channel busy on #{format_freq(target_freq)}")
            # Tune back — the caller (dwell_timeout) will tune to the next scan channel
            data
          else
            do_sounding_tx(data, target_freq, _async = true)
          end
        end
    end
  end

  # Common TX path for both sync and async sounding.
  defp do_sounding_tx(data, freq_hz, _include_probe) do
    symbols = Sounder.build_sounding_frame(data.self_addr,
      waveform: data.sounding_waveform,
      include_probe: true
    )
    transmit_frame(data.rig_id, symbols)

    new_schedule = Sounder.record_sounding_tx(data.sounding_schedule, freq_hz)

    # Persist to DB (don't block scan on failure)
    try do
      alias MinuteModemCore.Persistence.Callsigns
      Callsigns.record_sounding(data.self_addr, freq_hz,
        rig_id: data.rig_id,
        direction: "tx",
        frame_type: "sounding",
        source: "sounding"
      )
    rescue
      e -> Logger.warning("ALE Link [#{data.rig_id}] sounding DB write failed: #{inspect(e)}")
    end

    broadcast_event(data.rig_id, :sounding_tx, %{freq_hz: freq_hz, include_probe: true})

    %{data |
      sounding_schedule: new_schedule,
      soundings_this_cycle: data.soundings_this_cycle + 1
    }
  end

  # --- Scan configuration resolution ---

  # Canonical dwell times per ALE generation.
  # 2G: 392ms = time for one complete ALE word (MIL-STD-188-141A)
  # 3G: 500ms (MIL-STD-188-141B)
  # 4G: 500ms (MIL-STD-188-141D), though nets can override
  @scan_mode_dwell %{
    ale_2g: 392,
    ale_3g: 500,
    ale_4g: 500
  }

  @doc false
  # Resolve the full scan configuration from options.
  #
  # Returns `%{channels: [...], scan_dwell_ms: integer, scan_mode: atom}`
  #
  # Resolution priority for dwell time:
  #   1. Explicit `:scan_dwell_ms` in opts — operator override, always wins
  #   2. `:net_id` → net's `timing_config["scan_dwell_ms"]` if present
  #   3. `:scan_mode` → canonical dwell for that ALE generation
  #   4. Net's `net_type` (if loading by net_id) → canonical dwell
  #   5. System default (500ms)
  #
  # Resolution priority for channels:
  #   1. Explicit `:channels` in opts
  #   2. `:net_id` → net's channel set
  #   3. Fall back to data.channels (which defaults to @default_channels)
  defp resolve_scan_config(opts, data) do
    explicit_dwell = Keyword.get(opts, :scan_dwell_ms)
    scan_mode = Keyword.get(opts, :scan_mode)
    net_id = Keyword.get(opts, :net_id)
    explicit_channels = Keyword.get(opts, :channels)

    # Load net if specified
    net = if net_id, do: load_net(net_id), else: nil

    # Resolve channels
    channels = cond do
      explicit_channels ->
        normalize_channels(explicit_channels)
      net ->
        normalize_channels(net.channels)
      true ->
        data.channels
    end

    # Resolve scan mode — explicit > net type > default
    resolved_mode = cond do
      scan_mode ->
        scan_mode
      net ->
        parse_scan_mode(net.net_type)
      true ->
        :ale_4g
    end

    # Resolve dwell time — explicit > net timing > mode canonical > default
    resolved_dwell = cond do
      explicit_dwell ->
        explicit_dwell
      net && get_in(net.timing_config, ["scan_dwell_ms"]) ->
        net.timing_config["scan_dwell_ms"]
      true ->
        Map.get(@scan_mode_dwell, resolved_mode, data.timing.scan_dwell_ms)
    end

    %{
      channels: channels,
      scan_dwell_ms: resolved_dwell,
      scan_mode: resolved_mode,
      sounding_enabled: resolve_sounding_enabled(net, opts),
      sounding_interval_s: resolve_sounding_interval(net, opts),
      sounding_waveform: resolve_sounding_waveform(net, opts)
    }
  end

  defp resolve_sounding_enabled(nil, opts), do: Keyword.get(opts, :sounding_enabled, false)
  defp resolve_sounding_enabled(net, opts) do
    Keyword.get(opts, :sounding_enabled,
      get_in(net.timing_config, ["sounding_enabled"]) || false)
  end

  defp resolve_sounding_interval(nil, opts), do: Keyword.get(opts, :sounding_interval_s, 300)
  defp resolve_sounding_interval(net, opts) do
    Keyword.get(opts, :sounding_interval_s,
      get_in(net.timing_config, ["sounding_interval_s"]) || 300)
  end

  defp resolve_sounding_waveform(nil, opts), do: Keyword.get(opts, :sounding_waveform, :deep)
  defp resolve_sounding_waveform(net, opts) do
    configured = get_in(net.timing_config, ["sounding_waveform"])
    explicit = Keyword.get(opts, :sounding_waveform)
    case explicit || configured do
      "fast" -> :fast
      :fast -> :fast
      _ -> :deep
    end
  end

  defp load_net(net_id) do
    try do
      MinuteModemCore.Persistence.Nets.get_net(net_id)
    rescue
      _ -> nil
    end
  end

  # Normalize channel maps to a consistent format.
  # Accepts both string-keyed (from DB) and atom-keyed maps.
  defp normalize_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(&normalize_channel/1)
    |> Enum.filter(fn ch -> ch.freq_hz != nil end)
  end

  defp normalize_channel(%{freq_hz: _} = ch), do: ch

  defp normalize_channel(ch) when is_map(ch) do
    %{
      freq_hz: Map.get(ch, "freq_hz") || Map.get(ch, :freq_hz),
      name: Map.get(ch, "name") || Map.get(ch, :name, ""),
      mode: parse_mode(Map.get(ch, "mode") || Map.get(ch, :mode, "usb"))
    }
  end

  defp parse_mode(mode) when is_atom(mode), do: mode
  defp parse_mode(mode) when is_binary(mode) do
    try do
      String.to_existing_atom(mode)
    rescue
      ArgumentError -> :usb
    end
  end
  defp parse_mode(_), do: :usb

  defp parse_scan_mode("ale_2g"), do: :ale_2g
  defp parse_scan_mode("ale_3g"), do: :ale_3g
  defp parse_scan_mode("ale_4g"), do: :ale_4g
  defp parse_scan_mode(_), do: :ale_4g

  # --- Channel accessors ---

  defp channel_freq(%{freq_hz: f}), do: f
  defp channel_freq(%{"freq_hz" => f}), do: f
  defp channel_freq(_), do: nil

  defp channel_name(%{name: n}) when n != nil and n != "", do: n
  defp channel_name(%{"name" => n}) when n != nil and n != "", do: n
  defp channel_name(ch), do: format_freq(channel_freq(ch))

  defp freq_at_index(channels, index) do
    case Enum.at(channels, index) do
      nil -> List.first(channels) |> channel_freq()
      ch -> channel_freq(ch)
    end
  end

  defp find_channel_index(channels, freq_hz) do
    Enum.find_index(channels, fn ch -> channel_freq(ch) == freq_hz end)
  end

  # Compute the absolute monotonic time at which LBT should begin
  # for a synchronous call to the given channel index.
  #
  # epoch and now_wall are in wall-clock (os_time) milliseconds.
  # now_mono is in monotonic milliseconds.
  # Returns a monotonic timestamp for lbt_at_ms.
  defp compute_lbt_time(epoch, call_ch_index, timing, n_channels, now_wall, now_mono) do
    dwell_ms = timing.scan_dwell_ms
    cycle_len = n_channels * dwell_ms
    ms_into_cycle = rem_nonneg(now_wall - epoch, cycle_len)
    target_dwell_start_in_cycle = call_ch_index * dwell_ms

    time_until_target_dwell = if target_dwell_start_in_cycle > ms_into_cycle do
      target_dwell_start_in_cycle - ms_into_cycle
    else
      target_dwell_start_in_cycle + cycle_len - ms_into_cycle
    end

    lbt_lead_time = timing.t_lbt + timing.t_tune

    # If the target dwell is too soon for a full LBT, wait for the next cycle
    time_until_lbt = time_until_target_dwell - lbt_lead_time
    if time_until_lbt <= 0 do
      now_mono + time_until_target_dwell + cycle_len - lbt_lead_time
    else
      now_mono + time_until_lbt
    end
  end

  # Non-negative remainder (Elixir's rem/2 can return negative for negative dividends)
  defp rem_nonneg(a, b) when b > 0 do
    r = rem(a, b)
    if r < 0, do: r + b, else: r
  end

  defp format_freq(nil), do: "unknown"
  defp format_freq(freq_hz) when freq_hz >= 1_000_000 do
    mhz = freq_hz / 1_000_000
    "#{Float.round(mhz, 3)} MHz"
  end
  defp format_freq(freq_hz), do: "#{freq_hz} Hz"

  # --- Safe calls (swallow noproc for optional processes) ---

  defp safe_call(fun) do
    try do
      fun.()
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, reason -> {:error, reason}
    end
  end

  # --- Broadcasting ---

  defp broadcast_state_change(rig_id, state, info) do
    broadcast(rig_id, {:ale_state_change, rig_id, state, info})
  end

  defp broadcast_event(rig_id, event, payload) do
    broadcast(rig_id, {:ale_event, rig_id, event, payload})
  end

  defp broadcast(rig_id, message) do
    group = {:minutemodem, :rig, rig_id}
    for pid <- :pg.get_members(:minutemodem_pg, group) do
      send(pid, message)
    end
    :ok
  rescue
    _ -> :ok
  end
end
