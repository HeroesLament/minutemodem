defmodule MinuteModemCore.ALE.LQA.Sounder do
  @moduledoc """
  Active LQA sounding: frame assembly, scheduling, and two-way exchange.

  Per MIL-STD-188-141D G.5.5.10, two active LQA mechanisms are provided:

  ## One-Way Sounding (G.5.5.10.1)

  A "sound" is an LSU_Status PDU containing the sender's address and status.
  Transmitted periodically on each channel in the active channel set to keep
  LQA data current for other stations.

  Rules:
  - LBT before sounding — do not sound if channel is occupied
  - In synchronous scan: send during the dwell on that channel
  - In asynchronous scan: precede with capture probe
  - Rate-limited to avoid excessive TX

  ## Two-Way LQA Exchange (G.5.5.10.2)

  A full call/response/terminate handshake with traffic_type = LQA Exchange.
  Both sides measure and store LQA from the handshake.

  ## Schedule State

  Sounding schedule is a plain map `%{freq_hz => DateTime.t()}` tracking
  when each frequency was last sounded. The Link FSM holds this in its
  process state and passes it to scheduling functions. On scan start,
  seed it with `init_schedule/1`. On sounding TX, update it with
  `record_sounding_tx/2` and persist via LQA.
  """

  alias MinuteModemCore.ALE.{PDU, Waveform}
  alias MinuteModemCore.Persistence.Callsigns

  require Logger

  # -------------------------------------------------------------------
  # Configuration
  # -------------------------------------------------------------------

  # Minimum seconds between soundings on the same frequency.
  @default_min_interval_s 300

  # Age in seconds after which a channel is considered stale.
  @default_stale_threshold_s 3600

  # Maximum soundings per full scan cycle.
  @default_max_per_cycle 1

  # Traffic type code for LQA Exchange (Table G-XV).
  @traffic_type_lqa_exchange 7

  # LSU_Term reason code for clean exchange termination.
  @reason_no_more_traffic 0

  # -------------------------------------------------------------------
  # Schedule Lifecycle
  # -------------------------------------------------------------------

  @doc """
  Build an initial sounding schedule from the database.

  Queries the most recent TX sounding timestamp per frequency for this rig
  and returns a map of `%{freq_hz => DateTime.t()}`.

  Call when the Link FSM starts scanning.
  """
  def init_schedule(rig_id) do
    try do
      Callsigns.list_recent_soundings(hours: 24)
      |> Enum.filter(fn s -> s.rig_id == rig_id and s.direction == "tx" end)
      |> Enum.group_by(& &1.freq_hz)
      |> Map.new(fn {freq, soundings} ->
        latest = soundings |> Enum.max_by(& &1.timestamp, DateTime)
        {freq, latest.timestamp}
      end)
    rescue
      _ -> %{}
    end
  end

  # -------------------------------------------------------------------
  # One-Way Sounding: Scheduling
  # -------------------------------------------------------------------

  @doc """
  Determine whether a sounding should be transmitted on this frequency.

  ## Parameters

  - `schedule` — the current sounding schedule map
  - `freq_hz` — the frequency to check
  - `opts`:
    - `:min_interval_s` — minimum seconds between soundings (default: #{@default_min_interval_s})
    - `:soundings_this_cycle` — count of soundings already sent this cycle (default: 0)
    - `:max_per_cycle` — cap per cycle (default: #{@default_max_per_cycle})
  """
  def should_sound?(schedule, freq_hz, opts \\ []) do
    min_interval = Keyword.get(opts, :min_interval_s, @default_min_interval_s)
    max_per_cycle = Keyword.get(opts, :max_per_cycle, @default_max_per_cycle)
    soundings_this_cycle = Keyword.get(opts, :soundings_this_cycle, 0)

    if soundings_this_cycle >= max_per_cycle do
      false
    else
      case Map.get(schedule, freq_hz) do
        nil ->
          true

        last_at ->
          elapsed = DateTime.diff(DateTime.utc_now(), last_at, :second)
          elapsed >= min_interval
      end
    end
  end

  @doc """
  Update the schedule after transmitting a sounding.

  Returns the updated schedule map. The caller (Link FSM) should also
  persist the sounding via `LQA.record_observation/5` or
  `Callsigns.record_sounding/3`.
  """
  def record_sounding_tx(schedule, freq_hz) do
    Map.put(schedule, freq_hz, DateTime.utc_now())
  end

  # -------------------------------------------------------------------
  # One-Way Sounding: Frame Assembly
  # -------------------------------------------------------------------

  @doc """
  Build a one-way sounding frame (LSU_Status PDU).

  Returns assembled symbols ready for transmission.

  ## Parameters

  - `self_addr` — the local station's ALE address
  - `opts`:
    - `:waveform` — `:deep` or `:fast` (default: `:deep`)
    - `:status` — station status code (default: 0 = normal)
    - `:include_probe` — prepend capture probe for cold-start receivers (default: true)
  """
  def build_sounding_frame(self_addr, opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :deep)
    status = Keyword.get(opts, :status, 0)
    include_probe = Keyword.get(opts, :include_probe, Keyword.get(opts, :async, true))

    pdu = %PDU.LsuStatus{
      caller_addr: self_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      status: status
    }

    pdu_binary = PDU.encode(pdu)

    Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      include_probe: include_probe,
      tuner_time_ms: 50,
      capture_probe_count: 1,
      preamble_count: 1
    )
  end

  @doc """
  Calculate the duration of a sounding frame in milliseconds.
  """
  def sounding_duration_ms(opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :deep)
    dummy_pdu = PDU.encode(%PDU.LsuStatus{caller_addr: 0, status: 0})
    timing = Waveform.frame_timing(dummy_pdu, waveform: waveform, tuner_time_ms: 0)
    round(timing.duration_ms)
  end

  # -------------------------------------------------------------------
  # Sounding Target Selection
  # -------------------------------------------------------------------

  @doc """
  Select the channel most in need of a sounding.

  Returns `{freq_hz, priority}` where priority is `:never` (no data),
  `:stale` (older than threshold), or `nil` if all channels are fresh.

  ## Options

  - `:stale_threshold_s` — seconds before data is stale
    (default: #{@default_stale_threshold_s})
  """
  def next_sounding_target(schedule, channels, opts \\ []) do
    stale_threshold = Keyword.get(opts, :stale_threshold_s, @default_stale_threshold_s)
    now = DateTime.utc_now()

    ranked =
      channels
      |> Enum.map(fn ch ->
        freq = ch.freq_hz || ch[:freq_hz] || ch["freq_hz"]
        case Map.get(schedule, freq) do
          nil ->
            {freq, :never, 0}

          last_at ->
            age = DateTime.diff(now, last_at, :second)
            priority = if age >= stale_threshold, do: :stale, else: :fresh
            {freq, priority, age}
        end
      end)
      |> Enum.sort_by(fn
        {_, :never, _} -> {0, 0}
        {_, :stale, age} -> {1, -age}
        {_, :fresh, _} -> {2, 0}
      end)

    case ranked do
      [{_freq, :fresh, _} | _] -> nil
      [{freq, priority, _} | _] -> {freq, priority}
      [] -> nil
    end
  end

  # -------------------------------------------------------------------
  # Two-Way LQA Exchange
  # -------------------------------------------------------------------

  @doc """
  Build call options for initiating a two-way LQA exchange.

  Returns a keyword list for `Link.call/3`.
  """
  def exchange_call_opts(_dest_addr, opts \\ []) do
    base = [
      traffic_type: @traffic_type_lqa_exchange,
      waveform: Keyword.get(opts, :waveform, :deep),
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, 50),
      voice: false
    ]

    case Keyword.get(opts, :freq_hz) do
      nil -> base
      freq -> [{:freq_hz, freq} | base]
    end
  end

  @doc """
  Check if a received LSU_Req is an LQA exchange request.
  """
  def lqa_exchange?(%PDU.LsuReq{traffic_type: tt}), do: tt == @traffic_type_lqa_exchange
  def lqa_exchange?(_), do: false

  @doc "The traffic type code for LQA Exchange."
  def traffic_type_lqa_exchange, do: @traffic_type_lqa_exchange

  @doc "The LSU_Term reason code for clean exchange termination."
  def reason_no_more_traffic, do: @reason_no_more_traffic
end
