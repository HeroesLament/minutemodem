defmodule MinuteModemCore.Settings.Manager do
  use GenServer

  alias MinuteModemCore.Settings.Schema

  @name __MODULE__
  @max_revisions 100

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @spec current() :: Schema.t()
  def current do
    GenServer.call(@name, :current)
  end

  @spec propose(map()) :: :ok | {:error, term()}
  def propose(config_attrs) do
    GenServer.call(@name, {:propose, config_attrs})
  end

  @spec rollback(non_neg_integer()) :: :ok | {:error, term()}
  def rollback(version) do
    GenServer.call(@name, {:rollback, version})
  end

  ## ------------------------------------------------------------------
  ## GenServer callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    initial = Schema.default()

    state = %{
      current: initial,
      history: [initial],
      next_version: initial.version + 1
    }

    {:ok, state}
  end

  ## ------------------------------------------------------------------
  ## Calls
  ## ------------------------------------------------------------------

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.current, state}
  end

  @impl true
  def handle_call({:propose, attrs}, _from, state) do
    new_config =
      state.current
      |> Schema.merge(attrs)
      |> Map.put(:version, state.next_version)

    case Schema.validate(new_config) do
      :ok ->
        updated = %{
          state
          | current: new_config,
            history: take_last([new_config | state.history], @max_revisions),
            next_version: state.next_version + 1
        }

        {:reply, :ok, updated}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:rollback, version}, _from, state) do
    case Enum.find(state.history, &(&1.version == version)) do
      nil ->
        {:reply, {:error, :version_not_found}, state}

      old_config ->
        rolled =
          old_config
          |> Map.put(:version, state.next_version)

        updated = %{
          state
          | current: rolled,
            history: take_last([rolled | state.history], @max_revisions),
            next_version: state.next_version + 1
        }

        {:reply, :ok, updated}
    end
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp take_last(list, max) do
    Enum.take(list, max)
  end
end
