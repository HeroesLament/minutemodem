defmodule MinuteModemCore.Rig.SimnetClient do
  @moduledoc """
  Distributed client for communicating with MinutemodemSimnet.

  Makes RPC calls to the simnet node. The simnet node name is configured via:

      config :minutemodem_core, :simnet_node, :"simnet@hostname"

  If not configured, defaults to :"node1@" <> current hostname.
  """

  require Logger

  ## ------------------------------------------------------------------
  ## Connection Status
  ## ------------------------------------------------------------------

  def available? do
    node = simnet_node()
    node in Node.list() or node == Node.self()
  end

  def simnet_node do
    case Application.get_env(:minutemodem_core, :simnet_node) do
      nil ->
        [_, host] = Node.self() |> Atom.to_string() |> String.split("@")
        String.to_atom("node1@#{host}")

      node when is_atom(node) ->
        node
    end
  end

  def ensure_connected do
    node = simnet_node()
    if node in Node.list() do
      :ok
    else
      case Node.connect(node) do
        true -> :ok
        false -> {:error, :node_unreachable}
        :ignored -> {:error, :not_distributed}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Rig Attachment
  ## ------------------------------------------------------------------

  def attach_rig(rig_id, physical_config) do
    case rpc_call(MinutemodemSimnet, :attach_rig, [rig_id, physical_config]) do
      {:badrpc, reason} -> {:error, {:simnet_unreachable, reason}}
      result -> result
    end
  end

  def detach_rig(rig_id) do
    case rpc_call(MinutemodemSimnet, :detach_rig, [rig_id]) do
      {:badrpc, _} -> :ok
      result -> result
    end
  end

  ## ------------------------------------------------------------------
  ## RX Subscription
  ## ------------------------------------------------------------------

  def subscribe_rx(rig_id, pid) do
    case rpc_call(MinutemodemSimnet, :subscribe_rx, [rig_id, pid]) do
      {:badrpc, reason} -> {:error, {:simnet_unreachable, reason}}
      result -> result
    end
  end

  def unsubscribe_rx(rig_id) do
    case rpc_call(MinutemodemSimnet, :unsubscribe_rx, [rig_id]) do
      {:badrpc, _} -> :ok
      result -> result
    end
  end

  ## ------------------------------------------------------------------
  ## Transmission
  ## ------------------------------------------------------------------

  def tx(rig_id, t0, samples, opts \\ []) do
    case rpc_call(MinutemodemSimnet, :tx, [rig_id, t0, samples, opts]) do
      {:badrpc, reason} -> {:error, {:simnet_unreachable, reason}}
      result -> result
    end
  end

  ## ------------------------------------------------------------------
  ## Channel Info
  ## ------------------------------------------------------------------

  def get_channel(rig_id) do
    case rpc_call(MinutemodemSimnet, :get_channel, [rig_id]) do
      {:badrpc, _} -> nil
      result -> result
    end
  end

  def list_rigs do
    case rpc_call(MinutemodemSimnet, :list_rigs, []) do
      {:badrpc, _} -> []
      result -> result
    end
  end

  ## ------------------------------------------------------------------
  ## Internal
  ## ------------------------------------------------------------------

  defp rpc_call(module, function, args) do
    node = simnet_node()

    if node == Node.self() do
      apply(module, function, args)
    else
      :rpc.call(node, module, function, args)
    end
  end
end
