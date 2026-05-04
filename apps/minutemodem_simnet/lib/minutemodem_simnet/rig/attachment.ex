defmodule MinutemodemSimnet.Rig.Attachment do
  @moduledoc """
  Handles rig attachment to the simnet fabric.

  Serialized as a GenServer to prevent concurrent attach/detach races.

  ## Lifecycle Invariants

  - Exactly 0 or 1 combiner per rig
  - channel(A→B) exists ⟺ A attached ∧ B attached
  - attach_rig is idempotent (detach-then-attach if already present)
  - detach_rig is idempotent (no-op if not present)
  """

  use GenServer
  require Logger

  alias MinutemodemSimnet.Rig.Store
  alias MinutemodemSimnet.RxCombiner
  alias MinutemodemSimnet.Epoch

  @default_antenna %{
    type: :dipole,
    height_wavelengths: 0.5,
    azimuth_deg: 0.0,
    gain_dbi: 2.1,
    nvis_gain_db: nil,
    skywave_gain_db: nil,
    groundwave_gain_db: nil
  }

  @default_physical %{
    location: nil,
    antenna: @default_antenna,
    tx_power_watts: 100.0,
    noise_floor_dbm: -100.0
  }

  # --- Client API (serialized through GenServer) ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def attach_rig(rig_id, config) do
    GenServer.call(__MODULE__, {:attach, rig_id, config}, 30_000)
  end

  def detach_rig(rig_id) do
    GenServer.call(__MODULE__, {:detach, rig_id}, 30_000)
  end

  def update_physical_config(rig_id, physical_updates) do
    case Store.get(rig_id) do
      {:ok, attachment} ->
        updated_physical = Map.merge(attachment.physical, physical_updates)
        updated_physical =
          if Map.has_key?(physical_updates, :antenna) do
            %{updated_physical | antenna: merge_antenna_config(physical_updates.antenna)}
          else
            updated_physical
          end
        Store.put(rig_id, %{attachment | physical: updated_physical})
      :error ->
        {:error, :rig_not_attached}
    end
  end

  def get_physical_config(rig_id) do
    case Store.get(rig_id) do
      {:ok, attachment} -> {:ok, attachment.physical}
      :error -> {:error, :rig_not_attached}
    end
  end

  def get_location(rig_id) do
    case Store.get(rig_id) do
      {:ok, %{physical: %{location: loc}}} when not is_nil(loc) -> {:ok, loc}
      {:ok, _} -> {:error, :no_location}
      :error -> {:error, :rig_not_attached}
    end
  end

  def assign_rig_to_group(rig_id, group_id) do
    case Store.get(rig_id) do
      {:ok, attachment} -> Store.put(rig_id, %{attachment | group_id: group_id})
      :error -> {:error, :rig_not_attached}
    end
  end

  def unassign_rig_from_group(rig_id), do: assign_rig_to_group(rig_id, nil)
  def get_attachment(rig_id), do: Store.get(rig_id)
  def list_attached_rigs, do: Store.list_all()

  def list_rigs_in_group(group_id) do
    Store.list_all()
    |> Enum.filter(fn {_id, att} -> att.group_id == group_id end)
    |> Enum.map(fn {id, _} -> id end)
  end

  # --- GenServer ---

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:attach, rig_id, config}, _from, state) do
    {:reply, do_attach(rig_id, config), state}
  end

  @impl true
  def handle_call({:detach, rig_id}, _from, state) do
    {:reply, do_detach(rig_id), state}
  end

  # --- Internal ---

  defp do_attach(rig_id, config) do
    ensure_epoch_running(config)

    case Store.get(rig_id) do
      {:ok, _} ->
        Logger.info("[Attachment] Re-attaching #{inspect(rig_id)}")
        do_detach(rig_id)
      :error -> :ok
    end

    capabilities = %{
      sample_rates: Map.fetch!(config, :sample_rates),
      block_ms: Map.fetch!(config, :block_ms),
      representation: Map.fetch!(config, :representation)
    }

    physical = %{
      location: Map.get(config, :location, @default_physical.location),
      antenna: merge_antenna_config(Map.get(config, :antenna, %{})),
      tx_power_watts: Map.get(config, :tx_power_watts, @default_physical.tx_power_watts),
      noise_floor_dbm: Map.get(config, :noise_floor_dbm, @default_physical.noise_floor_dbm)
    }

    attachment = %{
      rig_id: rig_id, node: node(), pid: self(),
      capabilities: capabilities, physical: physical,
      group_id: nil, attached_at: DateTime.utc_now()
    }

    case validate_capabilities(capabilities) do
      :ok ->
        :ok = Store.put(rig_id, attachment)
        ensure_combiner_mesh(rig_id, attachment)
        {:ok, attachment}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_detach(rig_id) do
    remove_from_mesh(rig_id)
    Store.delete(rig_id)
  end

  defp ensure_combiner_mesh(rig_id, attachment) do
    {:ok, epoch_meta} = Epoch.Store.get_metadata()
    {:ok, contract} = Epoch.Store.get_contract()

    block_samples = div(contract.sample_rate * 20, 1000)
    rx_freq_hz = 7_300_000

    combiner_opts = [
      noise_floor_dbm: attachment.physical.noise_floor_dbm,
      sample_rate: contract.sample_rate,
      block_samples: block_samples,
      seed: epoch_meta.seed,
      t0: epoch_meta.t0,
      rx_freq_hz: rx_freq_hz
    ]

    {:ok, my_pid} = RxCombiner.Supervisor.start_combiner(rig_id, combiner_opts)

    other_rigs = Store.list_all() |> Enum.reject(fn {id, _} -> id == rig_id end)

    if other_rigs != [] do
      Logger.info("[Attachment] Creating channels for #{inspect(rig_id)} <-> #{length(other_rigs)} other rig(s)")
    end

    for {other_id, _} <- other_rigs do
      params_in = compute_channel_params(other_id, rig_id)
      params_out = compute_channel_params(rig_id, other_id)
      freq_hz = Map.get(params_in, :freq_hz, rx_freq_hz)

      # Use PID directly for our own combiner (avoids Horde registry propagation delay)
      try do
        GenServer.call(my_pid, {:add_channel, other_id, params_in, freq_hz})
      catch
        :exit, reason ->
          Logger.warning("[Attachment] Could not add channel #{inspect(other_id)}→#{inspect(rig_id)}: #{inspect(reason)}")
      end

      # Use registry for the other rig's combiner (may be on a different node)
      # Retry a few times since Horde registry propagation is eventually consistent
      add_channel_with_retry(other_id, rig_id, params_out, freq_hz, 3)
    end

    :ok
  end

  defp remove_from_mesh(rig_id) do
    other_ids =
      Store.list_all()
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.reject(fn id -> id == rig_id end)

    for other_id <- other_ids do
      try do
        RxCombiner.Combiner.remove_channel(other_id, rig_id)
      catch
        :exit, _ -> :ok
      end
    end

    RxCombiner.Supervisor.terminate_combiner(rig_id)
  end

  defp add_channel_with_retry(to_rig, from_rig, params, freq_hz, 0) do
    Logger.warning("[Attachment] Giving up adding channel #{inspect(from_rig)}→#{inspect(to_rig)} after retries")
  end

  defp add_channel_with_retry(to_rig, from_rig, params, freq_hz, retries) do
    try do
      RxCombiner.Combiner.add_channel(to_rig, from_rig, params, freq_hz)
    catch
      :exit, _reason ->
        Process.sleep(200)
        add_channel_with_retry(to_rig, from_rig, params, freq_hz, retries - 1)
    end
  end

  defp compute_channel_params(from_id, to_id) do
    # Initial channel params use a mid-band default frequency.
    # Actual per-frequency params are computed dynamically when the
    # receiver tunes to a specific frequency (via set_rx_frequency → combiner).
    freq_hz = 7_300_000
    case MinutemodemSimnet.HFEngine.compute(from_id, to_id, freq_hz) do
      {:ok, params} -> Map.put(params, :freq_hz, freq_hz)
      {:error, _} ->
        # Fallback: benign channel (no fading, high SNR)
        %{delay_spread_ms: 0.1, doppler_bandwidth_hz: 0.0, snr_db: 50.0,
          regime: :groundwave, path_count: 1, distance_km: 0.0,
          sample_rate: 9600, carrier_freq_hz: 1800.0, freq_hz: freq_hz}
    end
  end

  defp ensure_epoch_running(config) do
    case Epoch.Store.current_epoch() do
      {:ok, _} -> :ok
      :error ->
        sr = config[:sample_rates] |> List.first() || 48000
        bms = config[:block_ms] |> List.first() || 2
        Logger.info("[Attachment] Auto-starting epoch: sample_rate=#{sr}, block_ms=#{bms}")
        MinutemodemSimnet.start_epoch(sample_rate: sr, block_ms: bms)
    end
  end

  defp merge_antenna_config(nil), do: @default_antenna
  defp merge_antenna_config(config) when is_map(config), do: Map.merge(@default_antenna, config)

  defp validate_capabilities(capabilities) do
    case Epoch.Store.get_contract() do
      {:ok, contract} -> validate_against_contract(capabilities, contract)
      :error -> :ok
    end
  end

  defp validate_against_contract(caps, contract) do
    cond do
      contract.sample_rate not in caps.sample_rates ->
        {:error, {:incompatible_sample_rate, contract.sample_rate}}
      contract.block_ms not in caps.block_ms ->
        {:error, {:incompatible_block_ms, contract.block_ms}}
      contract.representation not in caps.representation ->
        {:error, {:incompatible_representation, contract.representation}}
      true -> :ok
    end
  end
end
