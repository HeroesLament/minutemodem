defmodule MinuteModemCore.Audio.Manager do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def list_devices do
    GenServer.call(__MODULE__, :list_devices)
  end

  @impl true
  def handle_call(:list_devices, _from, state) do
    devices =
      Membrane.PortAudio.list_devices()
      |> Enum.map(&map_device/1)

    {:reply, devices, state}
  end

  defp map_device(device) do
    %{
      id: device.id,
      name: device.name,
      default_device: device.default_device,
      max_input_channels: device.max_input_channels,
      max_output_channels: device.max_output_channels,
      default_sample_rate: device.default_sample_rate,
      direction: direction(device)
    }
  end

  defp direction(%{max_input_channels: i, max_output_channels: o}) do
    cond do
      i > 0 and o > 0 -> :duplex
      i > 0 -> :input
      o > 0 -> :output
      true -> :none
    end
  end
end
