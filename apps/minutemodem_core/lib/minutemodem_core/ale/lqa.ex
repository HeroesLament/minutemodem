defmodule MinuteModemCore.ALE.LQA do
  @moduledoc """
  Link Quality Analysis engine.

  Records channel quality observations from decoded ALE frames and provides
  channel ranking for automatic frequency selection.

  ## Recording

  Every successfully decoded PDU is an LQA observation. Call `record_observation/4`
  from the receiver after decoding, passing the rig_id, source station address,
  current frequency, and decode metrics. The observation is scored and persisted
  to the lqa_soundings table.

  ## Scoring

  Each observation is assigned a composite score (0–100) based on:

  - **Probe correlation** (0–40 pts) — signal detection quality.
    Scales linearly from threshold (24) to max (96).
  - **Path metric delta** (0–40 pts) — Viterbi decode confidence.
    Log-scaled; higher delta = more confident decode.
  - **Average LLR magnitude** (0–20 pts) — soft-decision reliability.
    Saturates around |LLR| = 5.0.

  These weights are initial estimates. Calibrate against compliance test data
  by running sweeps and correlating score vs actual decode success rate.

  ## Channel Ranking

  `rank_channels/3` queries recent observations for a destination station
  on each candidate frequency, applies exponential time decay (recent
  observations dominate), and returns channels sorted by score.

  All queries are scoped by `rig_id` — different rigs have different
  antennas and propagation, so their LQA data is not interchangeable.
  """

  import Ecto.Query

  alias MinuteModemCore.Persistence.{Repo, Callsigns}
  alias MinuteModemCore.Persistence.Schemas.{LqaSounding, Callsign}
  alias MinuteModemCore.ALE.PDU

  require Logger

  # -------------------------------------------------------------------
  # Scoring
  # -------------------------------------------------------------------

  @doc """
  Compute a composite LQA score (0–100) from decode metrics.

  Accepts a map with any subset of:
  - `:probe_corr` — probe correlation / IQ consistency (0–100)
  - `:path_metric_delta` — Viterbi confidence margin (float, 0–16 typical)
  - `:avg_llr` — mean soft-decision LLR magnitude (float, 0–4.0 typical)

  Missing metrics contribute 0 to their component.

  ## Calibration (from LQAChannelTest Watterson sweep, 2026-02-21)

  Real decoder ranges (Rust Walsh correlator clamps LLR to ±4.0):
    path_metric_delta: 0–16 (saturates at ~16 for AWGN ≥ -3 dB)
    avg_llr: 0–4.0 (hard cap from correlator)
    probe_corr (CV-based): ~50 (noise/fading) to ~85 (clean AWGN)

  Target score mapping:
    AWGN +10 dB (100% link) → ~90
    Good  0 dB  (100% link) → ~70
    Poor +2 dB  (80% link)  → ~55
    Poor -5 dB  (50% link)  → ~35
    Failed decode            → 0
  """
  def score(metrics) when is_map(metrics) do
    probe = score_probe(Map.get(metrics, :probe_corr, 0))
    viterbi = score_viterbi(Map.get(metrics, :path_metric_delta, 0.0))
    llr = score_llr(Map.get(metrics, :avg_llr, 0.0))

    Float.round(probe + viterbi + llr, 1)
  end

  # Probe correlation (IQ consistency): 0–30 points.
  # Real range: ~50 (fading/noise) to ~85 (clean AWGN).
  # Below 40 = 0 (noise floor). Linear from 40 to 90.
  defp score_probe(corr) when is_number(corr) do
    clamped = max(0.0, min(100.0, corr))
    if clamped < 40.0, do: 0.0, else: (clamped - 40.0) / 50.0 * 30.0
  end

  # Path metric delta: 0–40 points.
  # Real range: 0–16 (hard cap from LLR clamp at ±4.0).
  # Linear mapping: 0 at delta=0, 40 at delta=16.
  # A delta of ~3 is marginal (50% link), ~10 is good, ~16 is excellent.
  defp score_viterbi(delta) when is_number(delta) do
    clamped = max(0.0, min(16.0, delta))
    clamped / 16.0 * 40.0
  end

  # LLR magnitude: 0–30 points.
  # Real range: 0–4.0 (hard cap from Rust Walsh correlator).
  # A |LLR| of ~2.0 is marginal, ~3.0 is good, ~4.0 is excellent.
  # Linear mapping with saturation at 4.0.
  defp score_llr(avg) when is_number(avg) do
    clamped = max(0.0, min(4.0, avg))
    clamped / 4.0 * 30.0
  end

  # -------------------------------------------------------------------
  # Recording
  # -------------------------------------------------------------------

  @doc """
  Record an LQA observation from a decoded PDU.

  Called from the receiver's `process_complete_frame` after successful decode.
  Persists to the DB and updates the callsign's heard status.

  ## Parameters

  - `rig_id` — the rig that received the frame
  - `source_addr` — the remote station's ALE address (from the PDU)
  - `freq_hz` — the frequency the frame was received on
  - `metrics` — decode quality metrics map, may contain:
    - `:probe_corr` — probe correlation strength
    - `:path_metric_delta` — Viterbi decode confidence
    - `:path_metric` — Viterbi final path metric
    - `:avg_llr` — mean soft LLR magnitude
    - `:min_llr` — minimum soft LLR
    - `:preamble_zeros` — preamble detection quality
    - `:waveform` — :deep or :fast
    - `:decode_path` — :soft_iq, :hard, or :fast

  ## Options

  - `:frame_type` — "call", "response", "sounding", etc. (default: "call")
  - `:net_id` — net ID if known
  - `:snr_db` — SNR from simnet metadata, if available
  """
  def record_observation(rig_id, source_addr, freq_hz, metrics, opts \\ []) do
    lqa_score = score(metrics)

    extra = %{
      "lqa_score" => lqa_score,
      "probe_corr" => Map.get(metrics, :probe_corr),
      "path_metric_delta" => Map.get(metrics, :path_metric_delta),
      "path_metric" => Map.get(metrics, :path_metric),
      "avg_llr" => Map.get(metrics, :avg_llr),
      "min_llr" => Map.get(metrics, :min_llr),
      "preamble_zeros" => Map.get(metrics, :preamble_zeros),
      "waveform" => Map.get(metrics, :waveform) |> to_string_or_nil(),
      "decode_path" => Map.get(metrics, :decode_path) |> to_string_or_nil()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()

    Callsigns.record_sounding(source_addr, freq_hz,
      rig_id: rig_id,
      net_id: Keyword.get(opts, :net_id),
      snr_db: Keyword.get(opts, :snr_db),
      direction: "rx",
      frame_type: Keyword.get(opts, :frame_type, "call"),
      source: "inbound_call",
      extra: extra
    )
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  # -------------------------------------------------------------------
  # Channel Ranking
  # -------------------------------------------------------------------

  @doc """
  Rank candidate channels by LQA quality for a specific destination station.

  Queries recent observations for `dest_addr` on each candidate frequency,
  scoped to `rig_id`. Returns channels sorted best-first.

  ## Options

  - `:hours` — lookback window (default: 24)
  - `:decay_hours` — half-life for exponential time decay (default: 4).
    Observations older than this contribute less to the score.

  ## Returns

      [%{freq_hz: integer, score: float, last_heard: DateTime, count: integer}, ...]

  Channels with no observations are appended at the end with score 0.
  """
  def rank_channels(rig_id, dest_addr, channels, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    decay_hours = Keyword.get(opts, :decay_hours, 4)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    freq_list = Enum.map(channels, fn ch -> ch.freq_hz || ch[:freq_hz] || ch["freq_hz"] end)

    # Find the callsign record for this address
    case Callsigns.get_callsign_by_addr(dest_addr) do
      nil ->
        # No data for this station — return channels in original order, all score 0
        Enum.map(channels, fn ch ->
          freq = ch.freq_hz || ch[:freq_hz] || ch["freq_hz"]
          %{freq_hz: freq, score: 0.0, last_heard: nil, count: 0}
        end)

      callsign ->
        # Query all recent soundings for this callsign+rig on candidate frequencies
        soundings = Repo.all(
          from s in LqaSounding,
            where: s.callsign_id == ^callsign.id
              and s.rig_id == ^rig_id
              and s.freq_hz in ^freq_list
              and s.timestamp > ^cutoff,
            select: %{freq_hz: s.freq_hz, timestamp: s.timestamp, extra: s.extra}
        )

        # Group by frequency and compute time-decayed scores
        now = DateTime.utc_now()
        by_freq = Enum.group_by(soundings, & &1.freq_hz)

        scored = Enum.map(freq_list, fn freq ->
          case Map.get(by_freq, freq, []) do
            [] ->
              %{freq_hz: freq, score: 0.0, last_heard: nil, count: 0}

            obs ->
              {weighted_sum, weight_total} =
                Enum.reduce(obs, {0.0, 0.0}, fn o, {ws, wt} ->
                  age_hours = DateTime.diff(now, o.timestamp, :second) / 3600.0
                  weight = :math.exp(-0.693 * age_hours / decay_hours)
                  obs_score = Map.get(o.extra || %{}, "lqa_score", 0.0)
                  {ws + obs_score * weight, wt + weight}
                end)

              avg_score = if weight_total > 0, do: weighted_sum / weight_total, else: 0.0
              last = obs |> Enum.map(& &1.timestamp) |> Enum.max(DateTime)

              %{freq_hz: freq, score: Float.round(avg_score, 1), last_heard: last, count: length(obs)}
          end
        end)

        Enum.sort_by(scored, & &1.score, :desc)
    end
  end

  @doc """
  Return the best channel for a destination, or nil if no LQA data exists.

  Convenience wrapper around `rank_channels/4`.
  """
  def best_channel(rig_id, dest_addr, channels, opts \\ []) do
    case rank_channels(rig_id, dest_addr, channels, opts) do
      [%{score: score} = best | _] when score > 0 -> best
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Per-Frequency Quality (across all stations)
  # -------------------------------------------------------------------

  @doc """
  Get aggregate channel quality for a frequency across all stations.

  Useful for the operator "which of my channels is alive?" view.

  ## Options

  - `:hours` — lookback window (default: 24)

  ## Returns

      %{freq_hz: integer, avg_score: float, station_count: integer,
        observation_count: integer, last_heard: DateTime}
  """
  def channel_quality(rig_id, freq_hz, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.one(
      from s in LqaSounding,
        where: s.rig_id == ^rig_id
          and s.freq_hz == ^freq_hz
          and s.timestamp > ^cutoff,
        select: %{
          freq_hz: ^freq_hz,
          observation_count: count(s.id),
          station_count: count(s.callsign_id, :distinct),
          avg_snr: avg(s.snr_db),
          last_heard: max(s.timestamp)
        }
    )
  end

  @doc """
  Get quality summary for all frequencies in a channel set.

  Returns a list of `channel_quality` results, one per frequency.
  """
  def channel_quality_all(rig_id, channels, opts \\ []) do
    Enum.map(channels, fn ch ->
      freq = ch.freq_hz || ch[:freq_hz] || ch["freq_hz"]
      channel_quality(rig_id, freq, opts)
    end)
  end

  # -------------------------------------------------------------------
  # Sounding Scheduling
  # -------------------------------------------------------------------

  @doc """
  Return the channel that most needs a sounding (oldest or no data).

  Used by the Link FSM during scanning to decide when to transmit a
  sounding frame. Returns `{freq_hz, last_sounding_at}` or `{freq_hz, nil}`
  for channels with no data.

  ## Options

  - `:hours` — lookback window (default: 24)
  """
  def stalest_channel(rig_id, channels, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    freq_list = Enum.map(channels, fn ch -> ch.freq_hz || ch[:freq_hz] || ch["freq_hz"] end)

    # Get most recent sounding timestamp per frequency
    recent = Repo.all(
      from s in LqaSounding,
        where: s.rig_id == ^rig_id
          and s.freq_hz in ^freq_list
          and s.timestamp > ^cutoff,
        group_by: s.freq_hz,
        select: {s.freq_hz, max(s.timestamp)}
    )
    |> Map.new()

    # Find the frequency with the oldest (or no) data
    freq_list
    |> Enum.map(fn freq -> {freq, Map.get(recent, freq)} end)
    |> Enum.sort_by(fn
      {_freq, nil} -> DateTime.from_unix!(0)
      {_freq, ts} -> ts
    end, DateTime)
    |> List.first()
  end

  # -------------------------------------------------------------------
  # Helpers for extracting source address from PDUs
  # -------------------------------------------------------------------

  @doc """
  Extract the remote station's ALE address from a decoded PDU.

  Returns the caller_addr for most PDU types, or nil for PDUs
  that don't carry an address (AMD text, DTM data).
  """
  def source_addr(%{caller_addr: addr}) when is_integer(addr), do: addr
  def source_addr(%{called_addr: addr}) when is_integer(addr), do: addr
  def source_addr(_), do: nil

  @doc """
  Determine the frame_type string for an LQA record based on PDU type.
  """
  def frame_type(%PDU.LsuReq{}), do: "call"
  def frame_type(%PDU.LsuConf{}), do: "response"
  def frame_type(%PDU.LsuTerm{}), do: "terminate"
  def frame_type(%PDU.LsuStatus{}), do: "sounding"
  def frame_type(_), do: "data"
end
