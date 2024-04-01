defmodule MinutemodemSimnet.Channel.Params do
  @moduledoc """
  Resolves channel parameters from group defaults and per-rig overrides.

  Parameters include:
  - delay_spread_ms: Appendix E delay spread
  - doppler_bandwidth_hz: Fading bandwidth per path
  - snr_db: Signal-to-noise ratio
  - delay_samples: Simulated propagation delay
  """

  alias MinutemodemSimnet.Epoch
  alias MinutemodemSimnet.Group

  defstruct [
    :delay_spread_ms,
    :doppler_bandwidth_hz,
    :snr_db,
    :delay_samples,
    :sample_rate,
    :freq_hz,
    :carrier_freq_hz,
    :regime,
    :distance_km
  ]

  @default_params %{
    delay_spread_ms: 2.0,
    doppler_bandwidth_hz: 1.0,
    snr_db: 10.0,
    delay_samples: 0,
    carrier_freq_hz: 1800.0
  }

  @doc """
  Resolves channel parameters by merging:
  1. Default parameters
  2. Group parameters (if rig is assigned to a group)
  3. Per-channel overrides
  """
  def resolve(overrides, %Epoch.Metadata{} = metadata) do
    contract = Epoch.Store.get_contract!()

    group_id = Map.get(overrides, :group_id)

    base_params =
      @default_params
      |> maybe_merge_group_params(group_id)
      |> Map.merge(overrides)
      |> Map.put(:sample_rate, contract.sample_rate)

    struct(__MODULE__, base_params)
  end

  defp maybe_merge_group_params(params, nil), do: params

  defp maybe_merge_group_params(params, group_id) do
    case Group.Store.get(group_id) do
      {:ok, group} ->
        Map.merge(params, group.channel_defaults || %{})

      :error ->
        params
    end
  end

  @doc """
  Converts delay spread from ms to samples.
  """
  def delay_spread_samples(%__MODULE__{} = params) do
    round(params.delay_spread_ms * params.sample_rate / 1000)
  end

  @doc """
  Validates parameters against Appendix E requirements.
  """
  def validate(%__MODULE__{} = params) do
    cond do
      params.delay_spread_ms < 0 ->
        {:error, :invalid_delay_spread}

      params.doppler_bandwidth_hz < 0 ->
        {:error, :invalid_doppler_bandwidth}

      params.sample_rate not in [9600, 76800] ->
        {:error, :invalid_sample_rate}

      true ->
        :ok
    end
  end
end
