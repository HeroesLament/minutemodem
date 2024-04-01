defmodule MinutemodemSimnet.Telemetry do
  @moduledoc """
  Telemetry events for simnet monitoring.

  Events:
  - [:simnet, :epoch, :start]
  - [:simnet, :epoch, :stop]
  - [:simnet, :channel, :created]
  - [:simnet, :channel, :destroyed]
  - [:simnet, :channel, :tx]
  - [:simnet, :channel, :rx]
  - [:simnet, :rig, :attached]
  - [:simnet, :rig, :detached]
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # Epoch events

  def epoch_started(epoch_id, metadata) do
    :telemetry.execute(
      [:simnet, :epoch, :start],
      %{system_time: System.system_time()},
      %{epoch_id: epoch_id, metadata: metadata}
    )
  end

  def epoch_stopped(epoch_id) do
    :telemetry.execute(
      [:simnet, :epoch, :stop],
      %{system_time: System.system_time()},
      %{epoch_id: epoch_id}
    )
  end

  # Channel events

  def channel_created(from_rig, to_rig, channel_id) do
    :telemetry.execute(
      [:simnet, :channel, :created],
      %{system_time: System.system_time()},
      %{from_rig: from_rig, to_rig: to_rig, channel_id: channel_id}
    )
  end

  def channel_destroyed(from_rig, to_rig, channel_id) do
    :telemetry.execute(
      [:simnet, :channel, :destroyed],
      %{system_time: System.system_time()},
      %{from_rig: from_rig, to_rig: to_rig, channel_id: channel_id}
    )
  end

  def channel_tx(from_rig, to_rig, t0, block_size) do
    :telemetry.execute(
      [:simnet, :channel, :tx],
      %{
        system_time: System.system_time(),
        block_size: block_size
      },
      %{from_rig: from_rig, to_rig: to_rig, t0: t0}
    )
  end

  def channel_rx(from_rig, to_rig, t0, block_size) do
    :telemetry.execute(
      [:simnet, :channel, :rx],
      %{
        system_time: System.system_time(),
        block_size: block_size
      },
      %{from_rig: from_rig, to_rig: to_rig, t0: t0}
    )
  end

  # Rig events

  def rig_attached(rig_id, node) do
    :telemetry.execute(
      [:simnet, :rig, :attached],
      %{system_time: System.system_time()},
      %{rig_id: rig_id, node: node}
    )
  end

  def rig_detached(rig_id) do
    :telemetry.execute(
      [:simnet, :rig, :detached],
      %{system_time: System.system_time()},
      %{rig_id: rig_id}
    )
  end
end
