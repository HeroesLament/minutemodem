defmodule MinutemodemSimnet.Routing.Router do
  @moduledoc """
  Routes TX blocks to destination rig combiners.

  When a rig transmits, the Router fans out the samples to every
  other rig's RxCombiner via cast. The combiner queues the samples
  for the next tick.

  This is now nearly stateless — no channel cache, no channel creation.
  Channels are managed entirely by the Attachment module and live
  inside the combiner NIF resources.
  """

  use GenServer
  require Logger

  alias MinutemodemSimnet.Rig.Store
  alias MinutemodemSimnet.RxCombiner.{Combiner, Registry}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Transmits a block from a rig. Fans out to all other rigs' combiners.

  ## Options
    * `:freq_hz` - Transmit frequency in Hz (required)
  """
  def tx(from_rig, t0, samples, opts \\ []) do
    GenServer.cast(__MODULE__, {:tx, from_rig, t0, samples, opts})
  end

  @doc """
  Clears any cached data. No-op in new architecture but kept for API compat.
  """
  def invalidate_cache do
    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:tx, from_rig, _t0, samples, opts}, state) do
    freq_hz = Keyword.get(opts, :freq_hz, 7_300_000)

    destinations =
      Store.list_all()
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.reject(fn id -> id == from_rig end)

    for to_rig <- destinations do
      case Registry.lookup(to_rig) do
        {:ok, pid} ->
          GenServer.cast(pid, {:push_tx, to_string(from_rig), samples, freq_hz})

        :error ->
          Logger.debug("[Router] No combiner for #{inspect(to_rig)}, skipping")
      end
    end

    {:noreply, state}
  end
end
