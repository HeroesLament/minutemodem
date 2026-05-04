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
  alias MinutemodemSimnet.RxCombiner

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
    hf_engine = Keyword.get(opts, :hf_engine, :naive)
    solar_conditions = Keyword.get(opts, :solar_conditions, %{ssn: 100, sfi: 150, k_index: 2})
    time_mode = Keyword.get(opts, :time_mode, :realtime)

    metadata = %Epoch.Metadata{
      epoch_id: :erlang.unique_integer([:positive, :monotonic]),
      seed: seed,
      t0: 0,
      hf_engine: hf_engine,
      solar_conditions: solar_conditions,
      time_mode: time_mode
    }

    contract = %Epoch.Contract{
      sample_rate: sample_rate,
      block_ms: block_ms,
      samples_per_block: div(sample_rate * block_ms, 1000),
      representation: :audio_f32
    }

    :ok = Epoch.Store.set_metadata(metadata)
    :ok = Epoch.Store.set_contract(contract)

    # Start the tick driver for this epoch
    Epoch.TickDriver.start_link(
      sample_rate: sample_rate,
      tick_ms: block_ms,
      t0: 0
    )

    {:reply, {:ok, metadata.epoch_id}, %{state | epoch_active: true}}
  end

  @impl true
  def handle_call(:stop_epoch, _from, %{epoch_active: false} = state) do
    {:reply, {:error, :no_active_epoch}, state}
  end

  @impl true
  def handle_call(:stop_epoch, _from, state) do
    :ok = RxCombiner.Supervisor.terminate_all()
    Epoch.TickDriver.stop()
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
