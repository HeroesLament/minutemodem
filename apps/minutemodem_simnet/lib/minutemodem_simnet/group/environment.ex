defmodule MinutemodemSimnet.Group.Environment do
  @moduledoc """
  Synthesizes channel parameters from physical rig configuration.

  This module calculates Watterson channel parameters based on:
  - Distance between rigs (from coordinates)
  - Frequency (determines propagation regime)
  - Antenna characteristics
  - TX power and noise floor
  - Time of day (ionospheric conditions)

  The output parameters are fed to the Appendix E physics engine.

  ## Propagation Regimes

  - **Groundwave**: Line-of-sight, no fading, stable phase. Used for short distances (<50km).
  - **NVIS**: Near-vertical incidence skywave, mild fading. Used for regional comms.
  - **Skip**: No propagation possible at this distance/frequency combination.
  - **Skywave (single hop)**: One ionospheric reflection, Rayleigh fading.
  - **Skywave (multi-hop)**: Multiple reflections, more severe fading.
  """

  alias MinutemodemSimnet.Group.Definition
  alias MinutemodemSimnet.Rig.Attachment

  # Speed of light for wavelength calculations
  @speed_of_light_m_s 299_792_458

  @doc """
  Computes channel parameters for a link between two rigs.

  Two forms:
  - `compute_channel_params(from_rig_id, to_rig_id, freq_hz, opts)` - frequency-aware
  - `compute_channel_params(group, from_rig, to_rig, opts)` - legacy group-based

  Returns Watterson model parameters derived from physical configuration.
  """
  def compute_channel_params(arg1, arg2, arg3, opts \\ [])

  def compute_channel_params(from_rig_id, to_rig_id, freq_hz, opts) when is_atom(from_rig_id) or is_binary(from_rig_id) do
    utc_now = Keyword.get(opts, :utc_now, DateTime.utc_now())

    with {:ok, from_attachment} <- get_attachment_safe(from_rig_id),
         {:ok, to_attachment} <- get_attachment_safe(to_rig_id) do

      from_physical = from_attachment.physical
      to_physical = to_attachment.physical

      # Calculate distance if both have locations
      distance_km = calculate_distance(from_physical.location, to_physical.location)

      # Determine propagation regime from distance + frequency
      regime = propagation_regime(distance_km, freq_hz)

      # Base parameters from propagation regime
      base_params = regime_base_params(regime, distance_km, freq_hz)

      # Apply antenna gains
      params_with_antenna = apply_antenna_gains(
        base_params,
        from_physical.antenna,
        to_physical.antenna,
        regime,
        freq_hz
      )

      # Apply TX power and noise floor
      params_with_power = apply_power_budget(
        params_with_antenna,
        from_physical.tx_power_watts,
        to_physical.noise_floor_dbm,
        distance_km,
        freq_hz
      )

      # Apply time-of-day effects (only for ionospheric propagation)
      params_with_diurnal = apply_diurnal_effects(params_with_power, utc_now, freq_hz, regime)

      # Add metadata
      final_params = Map.merge(params_with_diurnal, %{
        distance_km: distance_km,
        regime: regime,
        freq_hz: freq_hz
      })

      {:ok, final_params}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper to normalize Store.get return value
  defp get_attachment_safe(rig_id) do
    case Attachment.get_attachment(rig_id) do
      {:ok, attachment} -> {:ok, attachment}
      :error -> {:error, {:rig_not_attached, rig_id}}
      other -> other
    end
  end

  def compute_channel_params(%Definition{} = group, from_rig, to_rig, opts) do
    utc_now = Keyword.get(opts, :utc_now, DateTime.utc_now())

    base_params = group.channel_defaults

    base_params
    |> apply_legacy_geo_model(group.geo_model, from_rig, to_rig)
    |> apply_legacy_diurnal_effects(group, utc_now)
    |> apply_disturbance(group.disturbance_index)
    |> apply_noise_floor(group.noise_floor_db)
  end

  # Propagation regime determination

  @doc """
  Determines the propagation regime based on distance and frequency.
  """
  def propagation_regime(nil, _freq_hz), do: :unknown
  def propagation_regime(_distance_km, nil), do: :unknown

  def propagation_regime(distance_km, freq_hz) do
    freq_mhz = freq_hz / 1_000_000

    # Skip zone boundaries vary by frequency
    # Higher frequencies have larger skip zones
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
        # Fallback for edge cases
        :skywave_single_hop
    end
  end

  # Skip zone varies by frequency (rough model)
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 5, do: {400, 400}    # No skip on 80m/160m
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 8, do: {350, 500}    # 40m - small skip
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 12, do: {400, 800}   # 30m
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 16, do: {500, 1200}  # 20m
  defp skip_zone_bounds(freq_mhz) when freq_mhz < 22, do: {800, 1800}  # 15m
  defp skip_zone_bounds(freq_mhz), do: {1000, 2500}                     # 10m and above

  # Base parameters for each propagation regime
  #
  # IMPORTANT: Doppler bandwidth determines fading rate.
  # - doppler_bandwidth_hz = 0.0 means NO Rayleigh fading (AWGN only)
  # - doppler_bandwidth_hz > 0 enables Rayleigh fading with that Doppler spread
  #
  # Groundwave is line-of-sight with no multipath, so NO fading.
  # Skywave has ionospheric multipath, so Rayleigh fading applies.

  defp regime_base_params(:groundwave, distance_km, _freq_hz) do
    # Groundwave: Direct path, no ionospheric reflection
    # - No multipath → No Rayleigh fading
    # - Stable phase → doppler_bandwidth_hz = 0
    # - Some delay spread from ground reflections at longer distances
    %{
      delay_spread_ms: 0.1 + distance_km * 0.002,
      doppler_bandwidth_hz: 0.0,  # NO FADING - groundwave is stable!
      snr_db: 40.0 - distance_km * 0.3,
      path_count: 1
    }
  end

  defp regime_base_params(:nvis, distance_km, _freq_hz) do
    # NVIS: Near-vertical incidence skywave
    # - Short ionospheric path → mild fading
    # - O-ray and X-ray modes → some multipath
    %{
      delay_spread_ms: 1.0 + distance_km * 0.005,
      doppler_bandwidth_hz: 0.3,  # Mild fading
      snr_db: 25.0 - distance_km * 0.02,
      path_count: 2
    }
  end

  defp regime_base_params(:skip, _distance_km, _freq_hz) do
    # Skip zone: No propagation possible
    %{
      delay_spread_ms: 0.0,
      doppler_bandwidth_hz: 0.0,
      snr_db: -100.0,
      path_count: 0,
      skip_zone: true
    }
  end

  defp regime_base_params(:skywave_single_hop, distance_km, _freq_hz) do
    # Single-hop skywave: One ionospheric reflection
    # - True Rayleigh fading from ionospheric irregularities
    # - Doppler spread depends on ionospheric conditions
    %{
      delay_spread_ms: 2.0 + distance_km * 0.001,
      doppler_bandwidth_hz: 0.5 + distance_km * 0.0003,  # 0.5-1.7 Hz typical
      snr_db: 20.0 - distance_km * 0.005,
      path_count: 2
    }
  end

  defp regime_base_params(:skywave_multi_hop, distance_km, _freq_hz) do
    # Multi-hop skywave: Multiple ionospheric reflections
    # - More severe fading from multiple reflection points
    # - Higher Doppler spread
    hop_count = estimate_hop_count(distance_km)
    %{
      delay_spread_ms: 2.0 * hop_count + distance_km * 0.0005,
      doppler_bandwidth_hz: 0.5 + hop_count * 0.3,  # Increases with hops
      snr_db: 15.0 - hop_count * 3 - distance_km * 0.002,
      path_count: 2,
      hop_count: hop_count
    }
  end

  defp regime_base_params(:unknown, _distance_km, _freq_hz) do
    # Default to moderate skywave conditions when we can't calculate
    %{
      delay_spread_ms: 2.0,
      doppler_bandwidth_hz: 0.5,
      snr_db: 15.0,
      path_count: 2
    }
  end

  defp estimate_hop_count(distance_km) do
    # Rough estimate: ~2000-2500km per hop
    max(1, ceil(distance_km / 2200))
  end

  # Antenna gain calculations

  defp apply_antenna_gains(params, from_antenna, to_antenna, regime, freq_hz) do
    tx_gain = antenna_gain_for_regime(from_antenna, regime, freq_hz)
    rx_gain = antenna_gain_for_regime(to_antenna, regime, freq_hz)

    total_antenna_gain = tx_gain + rx_gain

    current_snr = Map.get(params, :snr_db, 0)
    Map.put(params, :snr_db, current_snr + total_antenna_gain)
  end

  defp antenna_gain_for_regime(nil, _regime, _freq_hz), do: 0.0

  defp antenna_gain_for_regime(antenna, regime, freq_hz) do
    # Check for explicit regime overrides first
    case regime do
      :nvis when not is_nil(antenna.nvis_gain_db) ->
        antenna.nvis_gain_db

      r when r in [:skywave_single_hop, :skywave_multi_hop] and not is_nil(antenna.skywave_gain_db) ->
        antenna.skywave_gain_db

      :groundwave when not is_nil(antenna.groundwave_gain_db) ->
        antenna.groundwave_gain_db

      _ ->
        # Calculate from antenna type
        calculate_antenna_gain(antenna, regime, freq_hz)
    end
  end

  defp calculate_antenna_gain(antenna, regime, freq_hz) do
    base_gain = antenna.gain_dbi || 2.1
    wavelength_m = @speed_of_light_m_s / freq_hz
    height_m = (antenna.height_wavelengths || 0.5) * wavelength_m

    # Simplified antenna pattern model
    case {antenna.type, regime} do
      # Dipole patterns
      {:dipole, :nvis} ->
        # High-angle radiation depends on height
        if antenna.height_wavelengths < 0.3, do: base_gain + 3, else: base_gain - 2

      {:dipole, :groundwave} ->
        base_gain - 3  # Poor low-angle from horizontal dipole

      {:dipole, _skywave} ->
        # Moderate for skywave
        if antenna.height_wavelengths >= 0.5, do: base_gain, else: base_gain - 3

      # Vertical antenna patterns
      {:vertical, :nvis} ->
        base_gain - 6  # Poor high-angle radiation

      {:vertical, :groundwave} ->
        base_gain + 3  # Excellent low-angle

      {:vertical, _skywave} ->
        base_gain + 2  # Good low-angle for skywave

      # Inverted-V (compromise)
      {:inverted_v, :nvis} ->
        base_gain + 1

      {:inverted_v, _} ->
        base_gain - 1

      # Whip (mobile, inefficient)
      {:whip, _} ->
        base_gain - 10  # Significant efficiency loss

      # Default
      _ ->
        base_gain
    end
  end

  # Power budget calculation

  defp apply_power_budget(params, tx_power_watts, rx_noise_floor_dbm, distance_km, freq_hz) do
    # Convert TX power to dBm
    tx_power_dbm = 10 * :math.log10(tx_power_watts * 1000)

    # Free space path loss (simplified, doesn't account for ionospheric absorption)
    # Real HF propagation is much more complex, but this gives reasonable relative values
    path_loss_db = case Map.get(params, :regime, :unknown) do
      :groundwave ->
        # Groundwave attenuation is higher
        40 + 35 * :math.log10(max(distance_km, 1)) + 20 * :math.log10(freq_hz / 1_000_000)

      :skip ->
        # Infinite loss in skip zone
        200.0

      _ ->
        # Skywave/NVIS - ionospheric propagation
        # Much less loss than free space due to reflection
        30 + 20 * :math.log10(max(distance_km, 1)) + 10 * :math.log10(freq_hz / 1_000_000)
    end

    # Calculate received signal level
    rx_signal_dbm = tx_power_dbm - path_loss_db + Map.get(params, :snr_db, 0)

    # SNR at receiver
    calculated_snr = rx_signal_dbm - rx_noise_floor_dbm

    # Clamp to reasonable range
    final_snr = min(50, max(-20, calculated_snr))

    Map.put(params, :snr_db, final_snr)
  end

  # Diurnal (time-of-day) effects
  #
  # IMPORTANT: Diurnal effects only apply to ionospheric propagation.
  # Groundwave is NOT affected by ionospheric conditions.

  defp apply_diurnal_effects(params, _utc_now, _freq_hz, :groundwave) do
    # Groundwave is NOT affected by ionospheric conditions
    # Return params unchanged
    params
  end

  defp apply_diurnal_effects(params, _utc_now, _freq_hz, :skip) do
    # Skip zone - no propagation regardless of time
    params
  end

  defp apply_diurnal_effects(params, utc_now, freq_hz, _regime) do
    # Ionospheric propagation (NVIS, skywave) IS affected by time of day
    hour = utc_now.hour
    freq_mhz = freq_hz / 1_000_000

    {snr_adj, doppler_adj} = diurnal_adjustments(hour, freq_mhz)

    base_snr = Map.get(params, :snr_db, 10.0)
    base_doppler = Map.get(params, :doppler_bandwidth_hz, 1.0)

    Map.merge(params, %{
      snr_db: base_snr + snr_adj,
      doppler_bandwidth_hz: base_doppler * doppler_adj
    })
  end

  defp diurnal_adjustments(hour, freq_mhz) do
    # Simplified diurnal model
    # Day: D-layer absorption (worse for lower freqs), stable ionosphere
    # Night: No D-layer, more variable ionosphere, higher freqs may not propagate
    # Twilight: Transitional, increased Doppler

    is_day = hour >= 6 and hour < 18
    is_twilight = (hour >= 5 and hour < 7) or (hour >= 17 and hour < 19)

    cond do
      is_twilight ->
        # Increased fading during transitions
        {-2, 1.5}

      is_day and freq_mhz < 10 ->
        # D-layer absorption affects lower frequencies during day
        {-3, 1.0}

      is_day ->
        # Higher frequencies propagate well during day
        {0, 1.0}

      not is_day and freq_mhz > 15 ->
        # Higher frequencies may lose propagation at night
        {-6, 1.3}

      true ->
        # Night, lower frequencies
        {2, 1.2}  # Often better at night!
    end
  end

  # Distance calculation

  defp calculate_distance(nil, _), do: nil
  defp calculate_distance(_, nil), do: nil
  defp calculate_distance({lat1, lon1}, {lat2, lon2}) do
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

  # Legacy API support (for backward compatibility)

  defp apply_legacy_geo_model(params, nil, _from, _to), do: params
  defp apply_legacy_geo_model(params, _geo_model, _from_rig, _to_rig), do: params

  defp apply_legacy_diurnal_effects(params, %Definition{} = _group, utc_now) do
    hour = utc_now.hour

    snr_adjustment =
      cond do
        hour >= 6 and hour < 18 -> 0.0
        hour >= 18 and hour < 20 -> -3.0
        hour >= 4 and hour < 6 -> -3.0
        true -> -6.0
      end

    doppler_adjustment =
      cond do
        hour >= 6 and hour < 18 -> 1.0
        true -> 1.5
      end

    base_snr = Map.get(params, :snr_db, 10.0)
    base_doppler = Map.get(params, :doppler_bandwidth_hz, 1.0)

    Map.merge(params, %{
      snr_db: base_snr + snr_adjustment,
      doppler_bandwidth_hz: base_doppler * doppler_adjustment
    })
  end

  defp apply_disturbance(params, disturbance_index) when disturbance_index > 0 do
    base_snr = Map.get(params, :snr_db, 10.0)
    base_doppler = Map.get(params, :doppler_bandwidth_hz, 1.0)

    Map.merge(params, %{
      snr_db: base_snr - disturbance_index * 5,
      doppler_bandwidth_hz: base_doppler * (1 + disturbance_index)
    })
  end

  defp apply_disturbance(params, _), do: params

  defp apply_noise_floor(params, noise_floor_db) do
    Map.put(params, :noise_floor_db, noise_floor_db)
  end
end
