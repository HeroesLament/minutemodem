defmodule MinutemodemSimnet.HFEngine do
  @moduledoc """
  Behaviour for HF propagation engines.

  An HF engine computes Watterson channel parameters (SNR, delay spread,
  doppler bandwidth) from physical inputs (station locations, frequency,
  time, solar conditions). The engine determines *how* parameters are
  calculated; the Watterson NIF always does the actual signal impairment.

  ## Available Engines

  - `:naive` — Simplified regime-based model (default). Good for unit tests
    and basic behavior verification. No solar activity dependence.

  - `:voacap` — VOACAP-style prediction with analytical ionospheric model.
    SSN-driven MUF/foF2, D-layer absorption, atmospheric noise. Good for
    realistic ALE testing and LQA validation.

  - `:iturp533` — Full ITU-R P.533 implementation. Monthly median
    ionospheric coefficients, complete MUF calculation, circuit reliability.
    Good for compliance testing and publication-grade predictions.

  ## Usage

  The engine is selected at epoch level:

      MinutemodemSimnet.start_epoch(
        sample_rate: 9600,
        block_ms: 2,
        hf_engine: :voacap,
        solar_conditions: %{ssn: 100, sfi: 150, k_index: 2}
      )

  Or switched at runtime:

      MinutemodemSimnet.set_hf_engine(:voacap, solar_conditions: %{ssn: 50})
  """

  @type channel_params :: %{
          required(:snr_db) => float(),
          required(:delay_spread_ms) => float(),
          required(:doppler_bandwidth_hz) => float(),
          required(:regime) => atom(),
          required(:path_count) => non_neg_integer(),
          optional(:distance_km) => float(),
          optional(:muf_mhz) => float(),
          optional(:fof2_mhz) => float(),
          optional(:reliability_pct) => float(),
          optional(:skip_zone) => boolean()
        }

  @type solar_conditions :: %{
          optional(:ssn) => non_neg_integer(),
          optional(:sfi) => float(),
          optional(:k_index) => non_neg_integer()
        }

  @type station :: %{
          location: {float(), float()},
          antenna: map(),
          tx_power_watts: number(),
          noise_floor_dbm: float()
        }

  @doc """
  Compute Watterson channel parameters for a link between two stations.

  Returns `{:ok, params}` where params contains at minimum:
  - `:snr_db` — signal-to-noise ratio
  - `:delay_spread_ms` — multipath delay spread
  - `:doppler_bandwidth_hz` — Doppler fading bandwidth (0 = no fading)
  - `:regime` — propagation regime atom
  - `:path_count` — number of propagation paths

  ## Options

  - `:utc_now` — override current time (default: `DateTime.utc_now()`)
  - `:solar_conditions` — `%{ssn: _, sfi: _, k_index: _}`
  """
  @callback compute_channel_params(
              from_station :: station(),
              to_station :: station(),
              freq_hz :: pos_integer(),
              opts :: keyword()
            ) :: {:ok, channel_params()} | {:error, term()}

  @doc "Human-readable name for logging."
  @callback name() :: String.t()

  # ---------------------------------------------------------------
  # Dispatcher — resolves active engine and delegates
  # ---------------------------------------------------------------

  @engine_modules %{
    naive: MinutemodemSimnet.HFEngine.Naive,
    voacap: MinutemodemSimnet.HFEngine.VOACAP,
    iturp533: MinutemodemSimnet.HFEngine.ITURP533
  }

  @doc """
  Compute channel parameters using the currently active HF engine.

  Resolves the engine from epoch metadata (or `:naive` if no epoch).
  Loads station physical configs from the attachment store.
  """
  def compute(from_rig_id, to_rig_id, freq_hz, opts \\ []) do
    engine_mod = resolve_engine()
    solar = resolve_solar_conditions()

    opts = Keyword.put_new(opts, :solar_conditions, solar)

    with {:ok, from_station} <- load_station(from_rig_id),
         {:ok, to_station} <- load_station(to_rig_id) do
      engine_mod.compute_channel_params(from_station, to_station, freq_hz, opts)
    end
  end

  @doc """
  Returns the module for a given engine name.
  """
  def engine_module(name) when is_atom(name) do
    Map.get(@engine_modules, name)
  end

  @doc """
  Returns the currently active engine module.
  """
  def resolve_engine do
    case MinutemodemSimnet.Epoch.Store.get_metadata() do
      {:ok, metadata} ->
        engine_name = Map.get(metadata, :hf_engine, :naive)
        Map.get(@engine_modules, engine_name, MinutemodemSimnet.HFEngine.Naive)

      :error ->
        MinutemodemSimnet.HFEngine.Naive
    end
  end

  @doc """
  Returns the current solar conditions from epoch metadata.
  """
  def resolve_solar_conditions do
    case MinutemodemSimnet.Epoch.Store.get_metadata() do
      {:ok, metadata} ->
        Map.get(metadata, :solar_conditions, %{ssn: 100, sfi: 150, k_index: 2})

      :error ->
        %{ssn: 100, sfi: 150, k_index: 2}
    end
  end

  # Load station physical config from the attachment store
  defp load_station(rig_id) do
    alias MinutemodemSimnet.Rig.Attachment

    case Attachment.get_attachment(rig_id) do
      {:ok, attachment} ->
        {:ok, attachment.physical}

      :error ->
        {:error, {:rig_not_attached, rig_id}}
    end
  end
end
