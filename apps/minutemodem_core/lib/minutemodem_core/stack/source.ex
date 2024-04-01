defmodule MinuteModemCore.Simulator.Source do
  use GenServer
  require Logger

  def start_link(%{signal_file: file}) do
    GenServer.start_link(__MODULE__, file)
  end

  @impl true
  def init(file) do
    Logger.info("Simulator RX source started: #{file}")
    schedule_tick()
    {:ok, %{file: file}}
  end

  @impl true
  def handle_info(:tick, state) do
    # placeholder: fake RX frame
    send(MinuteModemCore.Simulator.RX.Dispatcher, {:rx_samples, <<0::16>>})
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, 100)
  end
end
