defmodule MinuteModemCore.Interface.MIL110D.Listener do
  @moduledoc """
  TCP listener for MIL-STD-188-110D DTE connections.

  Listens on the configured port and accepts exactly ONE DTE connection.
  Per the spec (A.4.1): "Only one DTE at a time can control the modem.
  Attempts by a second DTE to establish a connection shall be rejected."

  When a DTE connects:
  1. Accept the connection
  2. Start a SessionFSM to manage the protocol
  3. Reject any subsequent connection attempts until the current one closes
  """

  use GenServer

  require Logger

  defstruct [
    :rig_id,
    :port,
    :listen_socket,
    :active_session  # pid of current SessionFSM, or nil
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Interface.Registry, {rig_id, :mil110d_listener}}}
  end

  @doc "Check if a DTE is currently connected"
  def connected?(rig_id) do
    GenServer.call(via(rig_id), :connected?)
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    port = Keyword.get(opts, :port, 3000)

    # Start listening
    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen_socket} ->
        Logger.info("[MIL110D.Listener] Listening on port #{port} for rig #{rig_id}")

        state = %__MODULE__{
          rig_id: rig_id,
          port: port,
          listen_socket: listen_socket,
          active_session: nil
        }

        # Start accepting connections
        send(self(), :accept)

        {:ok, state}

      {:error, reason} ->
        Logger.error("[MIL110D.Listener] Failed to listen on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.active_session != nil, state}
  end

  @impl true
  def handle_info(:accept, state) do
    # Accept in a non-blocking way by spawning a task
    # This lets us still handle other messages
    parent = self()

    Task.start(fn ->
      case :gen_tcp.accept(state.listen_socket) do
        {:ok, socket} ->
          # Transfer ownership to parent BEFORE sending message
          # Otherwise socket dies when Task exits
          :gen_tcp.controlling_process(socket, parent)
          send(parent, {:accepted, socket})

        {:error, reason} ->
          send(parent, {:accept_error, reason})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    Logger.debug("[MIL110D.Listener] Socket accepted, checking peername...")
    case :inet.peername(socket) do
      {:ok, {addr, port}} ->
        addr_str = :inet.ntoa(addr) |> to_string()
        Logger.debug("[MIL110D.Listener] Peername OK: #{addr_str}:#{port}")
        handle_new_connection(socket, addr_str, port, state)

      {:error, reason} ->
        # Socket already closed (e.g., nc -z)
        Logger.debug("[MIL110D.Listener] Connection closed before handshake: #{inspect(reason)}")
        :gen_tcp.close(socket)
        send(self(), :accept)
        {:noreply, state}
    end
  end

  defp handle_new_connection(socket, addr_str, port, state) do
    if state.active_session do
      # Already have a connection - reject per A.4.1
      Logger.warning("[MIL110D.Listener] Rejecting connection from #{addr_str}:#{port} - already connected")
      :gen_tcp.close(socket)

      # Continue accepting
      send(self(), :accept)
      {:noreply, state}
    else
      # Accept this connection
      Logger.info("[MIL110D.Listener] Accepted connection from #{addr_str}:#{port}")

      # Start session FSM
      case start_session(state.rig_id, socket) do
        {:ok, session_pid} ->
          # Monitor the session so we know when it terminates
          Process.monitor(session_pid)

          # Hand over socket control to the session
          :gen_tcp.controlling_process(socket, session_pid)

          # Tell session to proceed with handshake
          send(session_pid, :socket_ready)

          # Continue accepting (will reject until session ends)
          send(self(), :accept)

          {:noreply, %{state | active_session: session_pid}}

        {:error, reason} ->
          Logger.error("[MIL110D.Listener] Failed to start session: #{inspect(reason)}")
          :gen_tcp.close(socket)
          send(self(), :accept)
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:accept_error, :closed}, state) do
    Logger.info("[MIL110D.Listener] Listen socket closed")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:accept_error, reason}, state) do
    Logger.error("[MIL110D.Listener] Accept error: #{inspect(reason)}")
    # Try again after a delay
    Process.send_after(self(), :accept, 1000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if pid == state.active_session do
      Logger.info("[MIL110D.Listener] Session ended: #{inspect(reason)}")
      {:noreply, %{state | active_session: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp start_session(rig_id, socket) do
    # Start session FSM under the interface supervisor
    opts = [
      rig_id: rig_id,
      socket: socket
    ]

    # For now, start directly - could use DynamicSupervisor later
    MinuteModemCore.Interface.MIL110D.SessionFSM.start_link(opts)
  end
end
