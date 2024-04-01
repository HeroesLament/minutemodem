defmodule MinutemodemSimnet.Rig.Attachment do
  @moduledoc """
  Handles rig attachment to the simnet fabric.

  When a rig is in simulator mode (type: :test, control: :simulator),
  it attaches to simnet instead of a hardware radio backend.

  The rig provides its full physical configuration (location, antenna,
  power, etc.) which simnet uses to calculate propagation parameters.
  """

  alias MinutemodemSimnet.Rig.Store
  alias MinutemodemSimnet.Channel
  alias MinutemodemSimnet.Epoch

  @type antenna_config :: %{
          type: :dipole | :vertical | :inverted_v | :whip | :yagi | :custom,
          height_wavelengths: float(),
          azimuth_deg: float(),
          gain_dbi: float(),
          # Optional overrides for custom patterns
          nvis_gain_db: float() | nil,
          skywave_gain_db: float() | nil,
          groundwave_gain_db: float() | nil
        }

  @type capabilities :: %{
          sample_rates: [pos_integer()],
          block_ms: [pos_integer()],
          representation: [:audio_f32 | :iq_f32]
        }

  @type physical_config :: %{
          location: {float(), float()} | nil,
          antenna: antenna_config() | nil,
          tx_power_watts: float(),
          noise_floor_dbm: float()
        }

  @type attachment :: %{
          rig_id: atom() | String.t(),
          node: node(),
          pid: pid(),
          capabilities: capabilities(),
          physical: physical_config(),
          group_id: atom() | String.t() | nil,
          attached_at: DateTime.t()
        }

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

  @doc """
  Attaches a rig to the simnet fabric.

  The rig declares its capabilities and physical configuration.
  Simnet uses the physical config to calculate propagation parameters.

  ## Options

    * `:sample_rates` - List of supported sample rates (required)
    * `:block_ms` - List of supported block durations (required)
    * `:representation` - List of supported formats (required)
    * `:location` - `{lat, lon}` tuple for geo calculations
    * `:antenna` - Antenna configuration map
    * `:tx_power_watts` - Transmit power (default: 100)
    * `:noise_floor_dbm` - Receiver noise floor (default: -100)

  ## Example

      MinutemodemSimnet.attach_rig(:station_a, %{
        sample_rates: [9600, 48000],
        block_ms: [1, 2, 5],
        representation: [:audio_f32],
        location: {38.9072, -77.0369},
        antenna: %{
          type: :dipole,
          height_wavelengths: 0.5,
          azimuth_deg: 45.0,
          gain_dbi: 2.1
        },
        tx_power_watts: 100,
        noise_floor_dbm: -100
      })
  """
  def attach_rig(rig_id, config) do
    # Ensure an epoch is running (auto-start with defaults if not)
    ensure_epoch_running(config)

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
      rig_id: rig_id,
      node: node(),
      pid: self(),
      capabilities: capabilities,
      physical: physical,
      group_id: nil,
      attached_at: DateTime.utc_now()
    }

    case validate_capabilities(capabilities) do
      :ok ->
        :ok = Store.put(rig_id, attachment)
        {:ok, attachment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_epoch_running(config) do
    case Epoch.Store.current_epoch() do
      {:ok, _epoch} ->
        # Epoch already running
        :ok

      :error ->
        # No epoch - start one with rig's preferred settings or defaults
        sample_rate = config[:sample_rates] |> List.first() || 48000
        block_ms = config[:block_ms] |> List.first() || 2

        require Logger
        Logger.info("[Attachment] Auto-starting epoch: sample_rate=#{sample_rate}, block_ms=#{block_ms}")

        MinutemodemSimnet.start_epoch(sample_rate: sample_rate, block_ms: block_ms)
    end
  end

  @doc """
  Updates the physical configuration for an attached rig.

  Use this when rig parameters change (e.g., location for mobile stations).
  """
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

        updated = %{attachment | physical: updated_physical}
        Store.put(rig_id, updated)

      :error ->
        {:error, :rig_not_attached}
    end
  end

  @doc """
  Gets the physical configuration for a rig.
  """
  def get_physical_config(rig_id) do
    case Store.get(rig_id) do
      {:ok, attachment} -> {:ok, attachment.physical}
      :error -> {:error, :rig_not_attached}
    end
  end

  @doc """
  Gets the location for a rig, if configured.
  """
  def get_location(rig_id) do
    case Store.get(rig_id) do
      {:ok, %{physical: %{location: loc}}} when not is_nil(loc) -> {:ok, loc}
      {:ok, _} -> {:error, :no_location}
      :error -> {:error, :rig_not_attached}
    end
  end

  @doc """
  Detaches a rig from the simnet fabric.

  Terminates any channels involving this rig.
  """
  def detach_rig(rig_id) do
    terminate_rig_channels(rig_id)
    Store.delete(rig_id)
  end

  @doc """
  Assigns a rig to a simulator group.

  The rig will use the group's channel defaults and
  environment parameters.
  """
  def assign_rig_to_group(rig_id, group_id) do
    case Store.get(rig_id) do
      {:ok, attachment} ->
        updated = %{attachment | group_id: group_id}
        Store.put(rig_id, updated)

      :error ->
        {:error, :rig_not_attached}
    end
  end

  @doc """
  Removes a rig from its current group.
  """
  def unassign_rig_from_group(rig_id) do
    assign_rig_to_group(rig_id, nil)
  end

  @doc """
  Gets the current attachment for a rig.
  """
  def get_attachment(rig_id) do
    Store.get(rig_id)
  end

  @doc """
  Lists all attached rigs.
  """
  def list_attached_rigs do
    Store.list_all()
  end

  @doc """
  Lists rigs in a specific group.
  """
  def list_rigs_in_group(group_id) do
    Store.list_all()
    |> Enum.filter(fn {_id, attachment} -> attachment.group_id == group_id end)
    |> Enum.map(fn {id, _} -> id end)
  end

  # Private helpers

  defp merge_antenna_config(nil), do: @default_antenna
  defp merge_antenna_config(config) when is_map(config) do
    Map.merge(@default_antenna, config)
  end

  defp validate_capabilities(capabilities) do
    case Epoch.Store.get_contract() do
      {:ok, contract} ->
        validate_against_contract(capabilities, contract)

      :error ->
        # No active epoch, accept any capabilities
        :ok
    end
  end

  defp validate_against_contract(capabilities, contract) do
    cond do
      contract.sample_rate not in capabilities.sample_rates ->
        {:error, {:incompatible_sample_rate, contract.sample_rate}}

      contract.block_ms not in capabilities.block_ms ->
        {:error, {:incompatible_block_ms, contract.block_ms}}

      contract.representation not in capabilities.representation ->
        {:error, {:incompatible_representation, contract.representation}}

      true ->
        :ok
    end
  end

  defp terminate_rig_channels(rig_id) do
    Channel.Registry.all_channels()
    |> Enum.filter(fn {from, to} -> from == rig_id or to == rig_id end)
    |> Enum.each(fn {from, to} ->
      Channel.Supervisor.terminate_channel(from, to)
    end)
  end
end
