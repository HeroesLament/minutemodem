defmodule MinutemodemSimnet.HFEngine.Naive do
  @moduledoc """
  Simplified regime-based HF propagation engine.

  Uses distance + frequency to determine propagation regime (groundwave,
  NVIS, skip, skywave), then applies simplified models for SNR, delay
  spread, and Doppler bandwidth. Includes basic diurnal effects and
  antenna gain patterns.

  Does NOT model solar activity (SSN/SFI are ignored).

  This is the default engine, suitable for unit tests and basic behavior
  verification.
  """

  @behaviour MinutemodemSimnet.HFEngine

  @speed_of_light_m_s 299_792_458

  @impl true
  def name, do: "Naive (regime-based)"

  @impl true
  def compute_channel_params(from_station, to_station, freq_hz, opts \\ []) do
    utc_now = Keyword.get(opts, :utc_now, DateTime.utc_now())

    distance_km = calculate_distance(from_station.location, to_station.location)
    regime = propagation_regime(distance_km, freq_hz)
    base_params = regime_base_params(regime, distance_km, freq_hz)

    params =
      base_params
      |> apply_antenna_gains(from_station.antenna, to_station.antenna, regime, freq_hz)
      |> apply_power_budget(from_station.tx_power_watts, to_station.noise_floor_dbm, distance_km, freq_hz)
      |> apply_diurnal_effects(utc_now, freq_hz, regime)
      |> Map.merge(%{
        distance_km: distance_km,
        regime: regime,
        freq_hz: freq_hz
      })

    {:ok, params}
  end

  # ---------------------------------------------------------------
  # Propagation regime determination
  # ---------------------------------------------------------------

  def propagation_regime(nil, _freq_hz), do: :unknown
  def propagation_regime(_distance_km, nil), do: :unknown

  def propagation_regime(distance_km, freq_hz) do
    freq_mhz = freq_hz / 1_000_000
    {skip_min, skip_max} = skip_zone_bounds(freq_mhz)

    cond do
      distance_km < 50 ->
        :groundwave

      distance_km < skip_min and freq_mhz < 10 ->
        :nvis

      distance_km >= skip_min and distance_km < skip_max ->
        :skip

      distance_km >= skip_max and distance_km < 4000 ->
        :skywave_single_hop

      distance_km >= 4000 ->
        :skywave_multi_hop

      true ->
        :skywave_single_hop
    end
  end

  # Skip zone varies by frequency (rough model)
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 5, do: {400, 400}
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 8, do: {350, 500}
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 12, do: {400, 800}
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 16, do: {500, 1200}
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 22, do: {800, 1800}
  defp skip_zone_bounds(_freq_mhz), do: {1000, 2500}

  # ---------------------------------------------------------------
  # Base parameters per regime
  # ---------------------------------------------------------------

  defp regime_base_params(:groundwave, distance_km, _freq_hz) do
    %{
      delay_spread_ms: 0.1 + distance_km * 0.002,
      doppler_bandwidth_hz: 0.0,
      snr_db: 40.0 - distance_km * 0.3,
      path_count: 1
    }
  end

  defp regime_base_params(:nvis, distance_km, _freq_hz) do
    %{
      delay_spread_ms: 1.0 + distance_km * 0.005,
      doppler_bandwidth_hz: 0.3,
      snr_db: 25.0 - distance_km * 0.02,
      path_count: 2
    }
  end

  defp regime_base_params(:skip, _distance_km, _freq_hz) do
    %{
      delay_spread_ms: 0.0,
      doppler_bandwidth_hz: 0.0,
      snr_db: -100.0,
      path_count: 0,
      skip_zone: true
    }
  end

  defp regime_base_params(:skywave_single_hop, distance_km, _freq_hz) do
    %{
      delay_spread_ms: 2.0 + distance_km * 0.001,
      doppler_bandwidth_hz: 0.5 + distance_km * 0.0003,
      snr_db: 20.0 - distance_km * 0.005,
      path_count: 2
    }
  end

  defp regime_base_params(:skywave_multi_hop, distance_km, _freq_hz) do
    hop_count = max(1, ceil(distance_km / 2200))
    %{
      delay_spread_ms: 2.0 * hop_count + distance_km * 0.0005,
      doppler_bandwidth_hz: 0.5 + hop_count * 0.3,
      snr_db: 15.0 - hop_count * 3 - distance_km * 0.002,
      path_count: 2,
      hop_count: hop_count
    }
  end

  defp regime_base_params(:unknown, _distance_km, _freq_hz) do
    %{
      delay_spread_ms: 2.0,
      doppler_bandwidth_hz: 0.5,
      snr_db: 15.0,
      path_count: 2
    }
  end

  # ---------------------------------------------------------------
  # Antenna gains
  # ---------------------------------------------------------------

  defp apply_antenna_gains(params, from_antenna, to_antenna, regime, freq_hz) do
    tx_gain = antenna_gain_for_regime(from_antenna, regime, freq_hz)
    rx_gain = antenna_gain_for_regime(to_antenna, regime, freq_hz)
    Map.update!(params, :snr_db, &(&1 + tx_gain + rx_gain))
  end

  defp antenna_gain_for_regime(nil, _regime, _freq_hz), do: 0.0

  defp antenna_gain_for_regime(antenna, regime, freq_hz) do
    # Check for explicit regime overrides first
    nvis_gain = Map.get(antenna, :nvis_gain_db)
    skywave_gain = Map.get(antenna, :skywave_gain_db)
    groundwave_gain = Map.get(antenna, :groundwave_gain_db)

    case regime do
      :nvis when not is_nil(nvis_gain) ->
        nvis_gain

      r when r in [:skywave_single_hop, :skywave_multi_hop] and not is_nil(skywave_gain) ->
        skywave_gain

      :groundwave when not is_nil(groundwave_gain) ->
        groundwave_gain

      _ ->
        calculate_antenna_gain(antenna, regime, freq_hz)
    end
  end

  defp calculate_antenna_gain(antenna, regime, freq_hz) do
    base_gain = Map.get(antenna, :gain_dbi, 2.1)
    height_wl = Map.get(antenna, :height_wavelengths, 0.5)
    ant_type = Map.get(antenna, :type, :dipole)

    case {ant_type, regime} do
      {:dipole, :nvis} ->
        if height_wl < 0.3, do: base_gain + 3, else: base_gain - 2

      {:dipole, :groundwave} ->
        base_gain - 3

      {:dipole, _skywave} ->
        if height_wl >= 0.5, do: base_gain, else: base_gain - 3

      {:vertical, :nvis} -> base_gain - 6
      {:vertical, :groundwave} -> base_gain + 3
      {:vertical, _skywave} -> base_gain + 2

      {:inverted_v, :nvis} -> base_gain + 1
      {:inverted_v, _} -> base_gain - 1

      {:whip, _} -> base_gain - 10

      _ -> base_gain
    end
  end

  # ---------------------------------------------------------------
  # Power budget
  # ---------------------------------------------------------------

  defp apply_power_budget(params, tx_power_watts, rx_noise_floor_dbm, distance_km, freq_hz) do
    tx_power_dbm = 10 * :math.log10(tx_power_watts * 1000)

    path_loss_db = case Map.get(params, :regime, :unknown) do
      :groundwave ->
        40 + 35 * :math.log10(max(distance_km, 1)) + 20 * :math.log10(freq_hz / 1_000_000)

      :skip ->
        200.0

      _ ->
        30 + 20 * :math.log10(max(distance_km, 1)) + 10 * :math.log10(freq_hz / 1_000_000)
    end

    rx_signal_dbm = tx_power_dbm - path_loss_db + Map.get(params, :snr_db, 0)
    calculated_snr = rx_signal_dbm - rx_noise_floor_dbm
    final_snr = min(50, max(-20, calculated_snr))

    Map.put(params, :snr_db, final_snr)
  end

  # ---------------------------------------------------------------
  # Diurnal effects
  # ---------------------------------------------------------------

  defp apply_diurnal_effects(params, _utc_now, _freq_hz, :groundwave), do: params
  defp apply_diurnal_effects(params, _utc_now, _freq_hz, :skip), do: params

  defp apply_diurnal_effects(params, utc_now, freq_hz, _regime) do
    hour = utc_now.hour
    freq_mhz = freq_hz / 1_000_000
    {snr_adj, doppler_adj} = diurnal_adjustments(hour, freq_mhz)

    params
    |> Map.update!(:snr_db, &(&1 + snr_adj))
    |> Map.update!(:doppler_bandwidth_hz, &(&1 * doppler_adj))
  end

  defp diurnal_adjustments(hour, freq_mhz) do
    is_day = hour >= 6 and hour < 18
    is_twilight = (hour >= 5 and hour < 7) or (hour >= 17 and hour < 19)

    cond do
      is_twilight -> {-2, 1.5}
      is_day and freq_mhz < 10 -> {-3, 1.0}
      is_day -> {0, 1.0}
      not is_day and freq_mhz > 15 -> {-6, 1.3}
      true -> {2, 1.2}
    end
  end

  # ---------------------------------------------------------------
  # Distance calculation
  # ---------------------------------------------------------------

  defp calculate_distance(nil, _), do: nil
  defp calculate_distance(_, nil), do: nil
  defp calculate_distance({lat1, lon1}, {lat2, lon2}) do
    haversine_km(lat1, lon1, lat2, lon2)
  end
  # Handle list format from JSON configs
  defp calculate_distance([lat1, lon1], [lat2, lon2]) do
    haversine_km(lat1, lon1, lat2, lon2)
  end
  defp calculate_distance([lat1, lon1], {lat2, lon2}) do
    haversine_km(lat1, lon1, lat2, lon2)
  end
  defp calculate_distance({lat1, lon1}, [lat2, lon2]) do
    haversine_km(lat1, lon1, lat2, lon2)
  end

  defp haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
