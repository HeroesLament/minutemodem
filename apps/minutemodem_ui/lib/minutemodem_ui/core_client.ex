defmodule MinuteModemUI.CoreClient do
  @moduledoc """
  Distributed client for communicating with MinuteModemCore.

  Makes RPC calls to the core node. The core node name is configured via:

      config :minutemodem_ui, :core_node, :"core@hostname"

  If not configured, defaults to :"core@" <> current hostname.
  """

  @router MinuteModemCore.Control.Router

  ## ------------------------------------------------------------------
  ## Rig Operations
  ## ------------------------------------------------------------------

  def list_rigs do
    call(:list_rigs)
  end

  def create_rig(attrs) do
    call({:create_rig, attrs})
  end

  def update_rig(rig_id, attrs) do
    call({:update_rig, rig_id, attrs})
  end

  def delete_rig(rig_id) do
    call({:delete_rig, rig_id})
  end

  def get_rig(rig_id) do
    call({:get_rig, rig_id})
  end

  def start_rig(rig_id) do
    call({:start_rig, rig_id})
  end

  def stop_rig(rig_id) do
    call({:stop_rig, rig_id})
  end

  def rig_running?(rig_id) do
    case rpc_call(MinuteModemCore.Rig, :running?, [rig_id]) do
      {:badrpc, _} -> false
      result -> result
    end
  end

  def list_running_rigs do
    case rpc_call(MinuteModemCore.Rig, :list_running, []) do
      {:badrpc, _} -> []
      result -> result
    end
  end

  def ale_state(rig_id) do
    case rpc_call(MinuteModemCore.Rig, :ale_state, [rig_id]) do
      {:badrpc, _} -> {:idle, %{}}
      result -> result
    end
  end

  def ale_scan(rig_id, opts \\ []) do
    rpc_call(MinuteModemCore.Rig, :ale_scan, [rig_id, opts])
  end

  def ale_stop(rig_id) do
    rpc_call(MinuteModemCore.Rig, :ale_stop, [rig_id])
  end

  def ale_call(rig_id, dest, opts \\ []) do
    rpc_call(MinuteModemCore.Rig, :ale_call, [rig_id, dest, opts])
  end

  ## ------------------------------------------------------------------
  ## Audio Devices
  ## ------------------------------------------------------------------

  def list_audio_devices do
    case call(:list_audio_devices) do
      {:error, _} -> []
      devices -> devices
    end
  end

  ## ------------------------------------------------------------------
  ## Settings
  ## ------------------------------------------------------------------

  def get_settings do
    call(:get_settings)
  end

  def propose_settings(new_settings) do
    call({:propose_settings, new_settings})
  end

  def rollback_settings(version) do
    call({:rollback_settings, version})
  end

  ## ------------------------------------------------------------------
  ## Net Operations
  ## ------------------------------------------------------------------

  def list_nets do
    call(:list_nets)
  end

  def create_net(attrs) do
    call({:create_net, attrs})
  end

  def update_net(net_id, attrs) do
    call({:update_net, net_id, attrs})
  end

  def delete_net(net_id) do
    call({:delete_net, net_id})
  end

  def get_net(net_id) do
    call({:get_net, net_id})
  end

  ## ------------------------------------------------------------------
  ## Callsign Operations
  ## ------------------------------------------------------------------

  def list_callsigns do
    call(:list_callsigns)
  end

  def create_callsign(attrs) do
    call({:create_callsign, attrs})
  end

  def update_callsign(callsign_id, attrs) do
    call({:update_callsign, callsign_id, attrs})
  end

  def delete_callsign(callsign_id) do
    call({:delete_callsign, callsign_id})
  end

  def get_callsign(callsign_id) do
    call({:get_callsign, callsign_id})
  end

  def get_callsign_soundings(callsign_id, opts \\ []) do
    call({:get_callsign_soundings, callsign_id, opts})
  end

  ## ------------------------------------------------------------------
  ## Subscription (for real-time updates)
  ## ------------------------------------------------------------------

  def subscribe_ui do
    # Subscribe this process to receive updates from core
    cast({:subscribe, self()})
  end

  def unsubscribe_ui do
    cast({:unsubscribe, self()})
  end

  ## ------------------------------------------------------------------
  ## Connection Status
  ## ------------------------------------------------------------------

  def connected? do
    node = core_node()
    node in Node.list() or node == Node.self()
  end

  def core_node do
    case Application.get_env(:minutemodem_ui, :core_node) do
      nil ->
        # Default: core@<same-host>
        [_, host] = Node.self() |> Atom.to_string() |> String.split("@")
        String.to_atom("core@#{host}")

      node when is_atom(node) ->
        node
    end
  end

  ## ------------------------------------------------------------------
  ## Internal
  ## ------------------------------------------------------------------

  defp call(msg, timeout \\ 5000) do
    node = core_node()

    if node == Node.self() do
      # Same node - direct call
      GenServer.call(@router, msg, timeout)
    else
      # Remote node
      case GenServer.call({@router, node}, msg, timeout) do
        result -> result
      end
    end
  rescue
    e in [RuntimeError] ->
      {:error, {:connection_failed, e.message}}
  catch
    :exit, {:noproc, _} ->
      {:error, :core_not_running}

    :exit, {{:nodedown, _node}, _} ->
      {:error, :node_down}

    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  defp cast(msg) do
    node = core_node()

    if node == Node.self() do
      GenServer.cast(@router, msg)
    else
      GenServer.cast({@router, node}, msg)
    end
  end

  defp rpc_call(module, function, args) do
    node = core_node()

    if node == Node.self() do
      apply(module, function, args)
    else
      :rpc.call(node, module, function, args)
    end
  end
end
