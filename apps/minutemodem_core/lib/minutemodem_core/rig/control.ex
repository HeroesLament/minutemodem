defmodule MinuteModemCore.Rig.Control do
  @moduledoc """
  Per-rig control interface.

  Provides a unified API for rig control (frequency, mode, PTT)
  that dispatches to the appropriate backend:

  - `"rigctld"` - Hamlib rigctld via TCP (spawns rigctld as Port)
  - `"flrig"` - FLRig via XMLRPC
  - `"simulator"` / `"test"` - No-op, for testing

  The backend is determined by the rig's `control_type` field.
  """

  use GenServer

  require Logger

  defstruct [
    :rig_id,
    :control_type,
    :control_config,
    :backend_state,
    :frequency,
    :mode,
    :ptt,
    :tx_owner       # nil | :ale | :data | :voice
  ]

  # --- Public API ---

  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec, name: via(spec.id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :control}}}
  end

  @doc "Set frequency in Hz"
  def set_frequency(rig_id, freq_hz) do
    GenServer.call(via(rig_id), {:set_frequency, freq_hz})
  end

  @doc "Get current frequency in Hz"
  def get_frequency(rig_id) do
    GenServer.call(via(rig_id), :get_frequency)
  end

  @doc "Set mode (:usb, :lsb, :am, :fm, :cw, etc)"
  def set_mode(rig_id, mode) do
    GenServer.call(via(rig_id), {:set_mode, mode})
  end

  @doc "Get current mode"
  def get_mode(rig_id) do
    GenServer.call(via(rig_id), :get_mode)
  end

  @doc "Set PTT state (:on | :off)"
  def ptt(rig_id, state) when state in [:on, :off] do
    GenServer.call(via(rig_id), {:ptt, state})
  end

  @doc "Get current PTT state"
  def get_ptt(rig_id) do
    GenServer.call(via(rig_id), :get_ptt)
  end

  @doc """
  Acquire TX ownership. Asserts PTT on the hardware.
  Returns :ok if acquired, {:error, :busy} if another owner has it.
  """
  def acquire_tx(rig_id, owner) when owner in [:ale, :data, :voice] do
    GenServer.call(via(rig_id), {:acquire_tx, owner})
  end

  @doc """
  Release TX ownership. Deasserts PTT on the hardware.
  Only succeeds if caller matches current owner.
  """
  def release_tx(rig_id, owner) when owner in [:ale, :data, :voice] do
    GenServer.call(via(rig_id), {:release_tx, owner})
  end

  @doc "Get current TX owner. Returns nil | :ale | :data | :voice."
  def tx_owner(rig_id) do
    GenServer.call(via(rig_id), :tx_owner)
  end

  @doc """
  Get rig status for UI display.
  Returns a map suitable for the Rig Card faceplate.
  """
  def status(rig_id) do
    GenServer.call(via(rig_id), :status)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(spec) do
    control_type = spec.control_type || "simulator"
    control_config = spec.control_config || %{}

    state = %__MODULE__{
      rig_id: spec.id,
      control_type: control_type,
      control_config: control_config,
      frequency: nil,
      mode: nil,
      ptt: :off
    }

    case init_backend(control_type, control_config) do
      {:ok, backend_state} ->
        Logger.info(
          "[Rig.Control] Started for rig #{spec.id} (backend: #{control_type})"
        )

        {:ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        Logger.error(
          "[Rig.Control] Failed to init backend #{control_type}: #{inspect(reason)}"
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:set_frequency, freq_hz}, _from, state) do
    case backend_set_frequency(state, freq_hz) do
      :ok ->
        {:reply, :ok, %{state | frequency: freq_hz}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_frequency, _from, state) do
    {:reply, {:ok, state.frequency}, state}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) do
    case backend_set_mode(state, mode) do
      :ok ->
        {:reply, :ok, %{state | mode: mode}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_mode, _from, state) do
    {:reply, {:ok, state.mode}, state}
  end

  @impl true
  def handle_call({:ptt, ptt_state}, _from, state) do
    case backend_ptt(state, ptt_state) do
      :ok ->
        {:reply, :ok, %{state | ptt: ptt_state}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_ptt, _from, state) do
    {:reply, {:ok, state.ptt}, state}
  end

  # --- TX ownership ---

  @impl true
  def handle_call({:acquire_tx, owner}, _from, %{tx_owner: nil} = state) do
    case backend_ptt(state, :on) do
      :ok ->
        Logger.info("[Rig.Control] TX acquired by :#{owner} for rig #{state.rig_id}")
        {:reply, :ok, %{state | tx_owner: owner, ptt: :on}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:acquire_tx, _owner}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call({:release_tx, owner}, _from, %{tx_owner: owner} = state) do
    Logger.info("[Rig.Control] TX released by :#{owner} for rig #{state.rig_id}")

    # Deassert PTT even if backend errors — don't leave ownership stuck
    backend_ptt(state, :off)
    {:reply, :ok, %{state | tx_owner: nil, ptt: :off}}
  end

  def handle_call({:release_tx, _wrong_owner}, _from, state) do
    {:reply, {:error, :not_owner}, state}
  end

  @impl true
  def handle_call(:tx_owner, _from, state) do
    {:reply, state.tx_owner, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      rig_id: state.rig_id,
      control_type: state.control_type,
      frequency: state.frequency,
      mode: state.mode,
      ptt: state.ptt,
      tx_owner: state.tx_owner,
      backend_status: backend_status(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{backend_state: %{port: port}} = state) do
    # Handle rigctld port output
    Logger.debug("[Rig.Control] rigctld: #{String.trim(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{backend_state: %{port: port}} = state) do
    Logger.error("[Rig.Control] rigctld exited with code #{code}")
    # TODO: Restart logic or notify supervisor
    {:noreply, %{state | backend_state: %{state.backend_state | port: nil}}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Rig.Control] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Backend: Initialization ---

  defp init_backend("simulator", _config), do: {:ok, %{type: :simulator}}
  defp init_backend("test", _config), do: {:ok, %{type: :test}}

  defp init_backend("rigctld", config) do
    # Spawn rigctld as a port
    model = Map.get(config, "model", 1) |> to_string()
    device = Map.get(config, "device", "/dev/null")
    baud = Map.get(config, "baud", 9600) |> to_string()
    rigctld_path = Map.get(config, "rigctld_path", "rigctld")
    port_num = Map.get(config, "port", 4532)
    civaddr = Map.get(config, "civaddr")

    args = [
      "-m", model,
      "-r", device,
      "-s", baud,
      "-t", to_string(port_num)
    ]

    # Add CI-V address for Icom rigs (decimal value)
    args = if civaddr do
      args ++ ["-c", to_string(civaddr)]
    else
      args
    end

    Logger.info("[Rig.Control] Spawning: #{rigctld_path} #{Enum.join(args, " ")}")

    rigctld_executable = System.find_executable(rigctld_path)

    if is_nil(rigctld_executable) do
      {:error, {:rigctld_not_found, rigctld_path}}
    else
      port =
        Port.open({:spawn_executable, rigctld_executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      # Give rigctld a moment to start
      Process.sleep(500)

      # Connect TCP socket
      case :gen_tcp.connect(~c"127.0.0.1", port_num, [:binary, active: false], 2000) do
        {:ok, socket} ->
          {:ok, %{type: :rigctld, port: port, socket: socket}}

        {:error, reason} ->
          Port.close(port)
          {:error, {:tcp_connect, reason}}
      end
    end
  end

  defp init_backend("flrig", config) do
    host = Map.get(config, "host", "127.0.0.1")
    port = Map.get(config, "port", 12345)
    {:ok, %{type: :flrig, host: host, port: port}}
  end

  defp init_backend(unknown, _config) do
    {:error, {:unknown_backend, unknown}}
  end

  # --- Backend: Set Frequency ---

  defp backend_set_frequency(%{backend_state: %{type: :simulator}}, _freq), do: :ok
  defp backend_set_frequency(%{backend_state: %{type: :test}}, _freq), do: :ok

  defp backend_set_frequency(%{backend_state: %{type: :rigctld, socket: socket}}, freq) do
    rigctld_command(socket, "F #{freq}")
  end

  defp backend_set_frequency(%{backend_state: %{type: :flrig} = bs}, freq) do
    flrig_call(bs, "rig.set_frequency", [freq / 1.0])
  end

  # --- Backend: Set Mode ---

  defp backend_set_mode(%{backend_state: %{type: :simulator}}, _mode), do: :ok
  defp backend_set_mode(%{backend_state: %{type: :test}}, _mode), do: :ok

  defp backend_set_mode(%{backend_state: %{type: :rigctld, socket: socket}}, mode) do
    mode_str = mode_to_rigctld(mode)
    rigctld_command(socket, "M #{mode_str} 0")
  end

  defp backend_set_mode(%{backend_state: %{type: :flrig} = bs}, mode) do
    mode_str = mode_to_flrig(mode)
    flrig_call(bs, "rig.set_mode", [mode_str])
  end

  # --- Backend: PTT ---

  defp backend_ptt(%{backend_state: %{type: :simulator}}, _ptt), do: :ok
  defp backend_ptt(%{backend_state: %{type: :test}}, _ptt), do: :ok

  defp backend_ptt(%{backend_state: %{type: :rigctld, socket: socket}}, ptt) do
    ptt_val = if ptt == :on, do: "1", else: "0"
    rigctld_command(socket, "T #{ptt_val}")
  end

  defp backend_ptt(%{backend_state: %{type: :flrig} = bs}, ptt) do
    ptt_val = if ptt == :on, do: 1, else: 0
    flrig_call(bs, "rig.set_ptt", [ptt_val])
  end

  # --- Backend: Status ---

  defp backend_status(%{backend_state: %{type: :simulator}}), do: :connected
  defp backend_status(%{backend_state: %{type: :test}}), do: :connected
  defp backend_status(%{backend_state: %{type: :rigctld, socket: nil}}), do: :disconnected
  defp backend_status(%{backend_state: %{type: :rigctld}}), do: :connected
  defp backend_status(%{backend_state: %{type: :flrig}}), do: :connected
  defp backend_status(_), do: :unknown

  # --- Rigctld Helpers ---

  defp rigctld_command(socket, cmd) do
    case :gen_tcp.send(socket, cmd <> "\n") do
      :ok ->
        case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, response} ->
            if String.contains?(response, "RPRT 0") or not String.contains?(response, "RPRT") do
              :ok
            else
              {:error, {:rigctld, String.trim(response)}}
            end

          {:error, reason} ->
            {:error, {:recv, reason}}
        end

      {:error, reason} ->
        {:error, {:send, reason}}
    end
  end

  defp mode_to_rigctld(:usb), do: "USB"
  defp mode_to_rigctld(:lsb), do: "LSB"
  defp mode_to_rigctld(:am), do: "AM"
  defp mode_to_rigctld(:fm), do: "FM"
  defp mode_to_rigctld(:cw), do: "CW"
  defp mode_to_rigctld(:rtty), do: "RTTY"
  defp mode_to_rigctld(:data), do: "PKTUSB"
  defp mode_to_rigctld(other), do: to_string(other) |> String.upcase()

  # --- FLRig Helpers ---

  defp flrig_call(%{host: host, port: port}, method, params) do
    # TODO: Implement XMLRPC client
    # For now, just log
    Logger.debug("[Rig.Control] FLRig call: #{method}(#{inspect(params)}) to #{host}:#{port}")
    :ok
  end

  defp mode_to_flrig(:usb), do: "USB"
  defp mode_to_flrig(:lsb), do: "LSB"
  defp mode_to_flrig(:am), do: "AM"
  defp mode_to_flrig(:fm), do: "FM"
  defp mode_to_flrig(:cw), do: "CW"
  defp mode_to_flrig(other), do: to_string(other) |> String.upcase()
end
