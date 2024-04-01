defmodule MinutemodemSimnet.Control.Server do
  @moduledoc """
  Highlander singleton control server.

  This is the cluster-wide authority for:
  - Epoch lifecycle (start/stop)
  - Simulator group management
  - High-level policy decisions

  Writes authoritative facts to eParl stores.
  Does NOT handle hot-path audio routing.
  """
  use GenServer

  alias MinutemodemSimnet.Epoch
  alias MinutemodemSimnet.Channel

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__})
  end

  def start_epoch(opts) do
    GenServer.call({:global, __MODULE__}, {:start_epoch, opts})
  end

  def stop_epoch do
    GenServer.call({:global, __MODULE__}, :stop_epoch)
  end

  def epoch_active? do
    GenServer.call({:global, __MODULE__}, :epoch_active?)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      epoch_active: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_epoch, opts}, _from, %{epoch_active: true} = state) do
    {:reply, {:error, :epoch_already_active}, state}
  end

  @impl true
  def handle_call({:start_epoch, opts}, _from, state) do
    seed = Keyword.get(opts, :seed, :erlang.unique_integer([:positive]))
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    block_ms = Keyword.get(opts, :block_ms, 2)

    metadata = %Epoch.Metadata{
      epoch_id: :erlang.unique_integer([:positive, :monotonic]),
      seed: seed,
      t0: 0
    }

    contract = %Epoch.Contract{
      sample_rate: sample_rate,
      block_ms: block_ms,
      samples_per_block: div(sample_rate * block_ms, 1000),
      representation: :audio_f32
    }

    :ok = Epoch.Store.set_metadata(metadata)
    :ok = Epoch.Store.set_contract(contract)

    {:reply, {:ok, metadata.epoch_id}, %{state | epoch_active: true}}
  end

  @impl true
  def handle_call(:stop_epoch, _from, %{epoch_active: false} = state) do
    {:reply, {:error, :no_active_epoch}, state}
  end

  @impl true
  def handle_call(:stop_epoch, _from, state) do
    :ok = Channel.Supervisor.terminate_all()
    :ok = Epoch.Store.clear()

    {:reply, :ok, %{state | epoch_active: false}}
  end

  @impl true
  def handle_call(:epoch_active?, _from, state) do
    {:reply, state.epoch_active, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
