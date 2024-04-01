defmodule MinutemodemSimnet do
  @moduledoc """
  Distributed HF channel simulation fabric.

  Provides MIL-STD-188-110D Appendix E compliant channel simulation
  between rigs in a cluster.

  ## Quick Start

      # Attach a rig with physical configuration
      MinutemodemSimnet.attach_rig(:station_a, %{
        sample_rates: [9600, 48000],
        block_ms: [1, 2, 5],
        representation: [:audio_f32],
        location: {38.9072, -77.0369},  # Washington DC
        antenna: %{type: :dipole, height_wavelengths: 0.5},
        tx_power_watts: 100
      })

      # Subscribe to receive blocks destined for this rig
      MinutemodemSimnet.subscribe_rx(:station_a, self())

      # Start an epoch
      MinutemodemSimnet.start_epoch(sample_rate: 48000, block_ms: 2)

      # Transmit on 40m
      MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

      # Receive (from other rigs transmitting)
      receive do
        {:simnet_rx, from_rig, t0, samples, freq_hz, metadata} ->
          # Handle received block
          # metadata contains: %{regime: :nvis, snr_db: 18.5, ...}
      end

  ## Propagation Model

  Channel parameters (delay spread, Doppler, SNR) are computed from:
  - Distance between rigs (from coordinates)
  - Frequency (determines propagation regime: groundwave, NVIS, skywave)
  - Antenna characteristics
  - TX power and noise floor
  - Time of day (ionospheric conditions)
  """

  alias MinutemodemSimnet.Control
  alias MinutemodemSimnet.Epoch
  alias MinutemodemSimnet.Group
  alias MinutemodemSimnet.Rig
  alias MinutemodemSimnet.Routing

  # Epoch lifecycle
  defdelegate start_epoch(opts), to: Control.Server
  defdelegate stop_epoch(), to: Control.Server
  defdelegate current_epoch(), to: Epoch.Store

  # Simulator groups
  defdelegate create_group(id, params), to: Group.Store
  defdelegate update_group(id, params), to: Group.Store
  defdelegate delete_group(id), to: Group.Store
  defdelegate list_groups(), to: Group.Store

  # Rig attachment
  defdelegate attach_rig(rig_id, config), to: Rig.Attachment
  defdelegate detach_rig(rig_id), to: Rig.Attachment
  defdelegate assign_rig_to_group(rig_id, group_id), to: Rig.Attachment
  defdelegate update_rig_physical(rig_id, physical_updates), to: Rig.Attachment, as: :update_physical_config
  defdelegate get_rig_location(rig_id), to: Rig.Attachment, as: :get_location

  # Channel operations (called by rigs)

  @doc """
  Transmits a block from a rig.

  ## Options

    * `:freq_hz` - Transmit frequency in Hz (determines propagation model)

  ## Examples

      # TX on 40m (7.3 MHz)
      MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 7_300_000)

      # TX on 20m (14.1 MHz)
      MinutemodemSimnet.tx(:station_a, 0, samples, freq_hz: 14_100_000)
  """
  defdelegate tx(from_rig, t0, samples, opts \\ []), to: Routing.Router

  @doc """
  Subscribes to RX blocks destined for a rig.

  When other rigs transmit, the channel physics are applied and the
  resulting blocks are delivered to subscribers.

  ## Subscription types

    * `pid` - Messages sent as `{:simnet_rx, from_rig, t0, samples, freq_hz, metadata}`
    * `fun/1` - Called with `{:simnet_rx, from_rig, t0, samples, freq_hz, metadata}`

  Only one subscription per rig is allowed. New subscriptions replace old ones.

  ## Examples

      # Subscribe with pid
      MinutemodemSimnet.subscribe_rx(:my_rig, self())

      # Subscribe with callback
      MinutemodemSimnet.subscribe_rx(:my_rig, fn {:simnet_rx, from, t0, samples, freq, meta} ->
        IO.puts("RX from \#{from} at t0=\#{t0}, regime=\#{meta.regime}")
      end)

  ## Message format

      {:simnet_rx, from_rig, t0, samples, freq_hz, metadata}

  Where metadata contains:
    * `:regime` - Propagation regime (:nvis, :skywave_single_hop, etc.)
    * `:snr_db` - Signal-to-noise ratio
    * `:distance_km` - Path distance
    * `:doppler_bandwidth_hz` - Doppler spread
  """
  defdelegate subscribe_rx(rig_id, subscriber), to: Routing.RxRegistry, as: :subscribe

  @doc """
  Unsubscribes from RX blocks for a rig.
  """
  defdelegate unsubscribe_rx(rig_id), to: Routing.RxRegistry, as: :unsubscribe

  # Propagation utilities

  @doc """
  Computes propagation parameters between two rigs at a given frequency.

  Useful for debugging or displaying link quality.

  ## Example

      MinutemodemSimnet.compute_propagation(:station_a, :station_b, 7_300_000)
      # => {:ok, %{regime: :nvis, snr_db: 18.5, distance_km: 250, ...}}
  """
  defdelegate compute_propagation(from_rig, to_rig, freq_hz),
    to: Group.Environment,
    as: :compute_channel_params
end
