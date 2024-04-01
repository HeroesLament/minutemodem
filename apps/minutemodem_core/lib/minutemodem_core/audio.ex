defmodule MinuteModemCore.Audio do
  use GenServer
  require Logger

  alias MinuteModemCore.Audio.Pipeline

  ## Public API

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  ## GenServer callbacks

  @impl true
  def init(:ok) do
    Logger.info("Starting audio subsystem")

    case Pipeline.start_link() do
      {:ok, pipeline_pid, supervisor_pid} ->
        state = %{
          pipeline: pipeline_pid,
          supervisor: supervisor_pid
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start audio pipeline: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Shutting down audio subsystem: #{inspect(reason)}")

    if pid = state[:pipeline] do
      Process.exit(pid, :shutdown)
    end

    :ok
  end
end
