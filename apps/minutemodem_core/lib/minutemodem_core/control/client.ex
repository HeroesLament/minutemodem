defmodule MinuteModemCore.Control.Client do
  @moduledoc """
  Location-transparent client for MinuteModemCore.Control.Router.

  Used by UI nodes and local callers alike.
  """

  @router MinuteModemCore.Control.Router

  ## Public API

  def list_audio_devices do
    call(:list_audio_devices)
  end

  def list_rigs do
    call(:list_rigs)
  end

  def create_rig(attrs), do: call({:create_rig, attrs})
  def update_rig(rig_id, attrs), do: call({:update_rig, rig_id, attrs})
  def delete_rig(rig_id), do: call({:delete_rig, rig_id})
  def get_rig(rig_id), do: call({:get_rig, rig_id})
  def list_all_rigs, do: call(:list_all_rigs)
  def start_rig(rig_id), do: call({:start_rig, rig_id})
  def stop_rig(rig_id), do: call({:stop_rig, rig_id})



  ## Internal

  defp call(msg) do
    GenServer.call(router_ref(), msg)
  end

  defp router_ref do
    case Application.get_env(:minutemodem_core, :core_node) do
      nil ->
        # Same-node operation
        @router

      node ->
        # Distributed operation
        {@router, node}
    end
  end
end
