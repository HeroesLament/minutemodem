defmodule MinutemodemSimnet.Epoch.TickDriver do
  @moduledoc """
  Singleton tick driver for the epoch.

  Broadcasts {:epoch_tick, sample_index} to all RxCombiner processes
  at the epoch tick rate (default 20ms = 50 ticks/s).

  All combiners tick in response to the same broadcast, ensuring
  coherent sample_index across the cluster. This is the single
  clock source for the simnet data plane.

  Started by Control.Server when an epoch begins.
  Stopped when the epoch ends.
  """

  use GenServer
  require Logger

  @default_tick_ms 20

  defstruct [:sample_index, :samples_per_tick, :tick_ms, :timer]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__})
  end

  def stop do
    case GenServer.whereis({:global, __MODULE__}) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @impl true
  def init(opts) do
    sample_rate = Keyword.get(opts, :sample_rate, 9600)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    samples_per_tick = div(sample_rate * tick_ms, 1000)
    t0 = Keyword.get(opts, :t0, 0)

    # Ensure the pg group exists
    try do
      :pg.start_link(:simnet_pg)
    catch
      :error, {:already_started, _} -> :ok
    end

    Logger.info("[TickDriver] Started: #{sample_rate} Hz, #{tick_ms}ms tick, #{samples_per_tick} samp/tick")

    timer = Process.send_after(self(), :tick, tick_ms)

    {:ok, %__MODULE__{
      sample_index: t0,
      samples_per_tick: samples_per_tick,
      tick_ms: tick_ms,
      timer: timer
    }}
  end

  @impl true
  def handle_info(:tick, state) do
    # Broadcast to all combiner processes
    subscribers = :pg.get_members(:simnet_pg, :tick_subscribers)

    msg = {:epoch_tick, state.sample_index}
    for pid <- subscribers do
      send(pid, msg)
    end

    timer = Process.send_after(self(), :tick, state.tick_ms)

    {:noreply, %{state |
      sample_index: state.sample_index + state.samples_per_tick,
      timer: timer
    }}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Logger.info("[TickDriver] Stopped at sample_index=#{state.sample_index}")
    :ok
  end
end
