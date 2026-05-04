defmodule MinuteModemCore.LicenseGate do
  use GenServer

  def start_link(core_children) do
    GenServer.start_link(__MODULE__, core_children, name: __MODULE__)
  end

  def init(core_children) do
    {:ok, %{children: core_children}, {:continue, :check}}
  end

  def handle_continue(:check, state) do
    wait_for_iex_gl()
    LicenseTUI.Gate.require_license!()

    for child <- state.children do
      DynamicSupervisor.start_child(MinuteModemCore.CoreSupervisor, child)
    end

    {:noreply, state}
  end

  defp wait_for_iex_gl(attempts \\ 50)
  defp wait_for_iex_gl(0), do: :ok

  defp wait_for_iex_gl(attempts) do
    case MinuteModemCore.Application.find_iex_gl() do
      nil ->
        Process.sleep(100)
        wait_for_iex_gl(attempts - 1)

      gl ->
        Process.group_leader(self(), gl)
        :ok
    end
  end
end
