defmodule MinuteModemUI.Application do
  @moduledoc """
  MinuteModemUI OTP Application.

  Starts the UI scenes using wx_mvu.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # wx_mvu is already running (started as dependency)

    # Start our scenes
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.UI)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Rigs)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Nets)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Callsigns)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Config)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Ops)

    # Our own supervisor (for any non-UI processes)
    children = []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: MinuteModemUI.Supervisor
    )
  end

  @doc """
  Reload all scenes (useful for development).
  """
  def reload do
    WxMVU.stop_scene(MinuteModemUI.Scenes.Ops)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Callsigns)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Nets)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Rigs)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Config)
    WxMVU.stop_scene(MinuteModemUI.Scenes.UI)

    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.UI)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Config)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Rigs)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Nets)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Callsigns)
    {:ok, _} = WxMVU.start_scene(MinuteModemUI.Scenes.Ops)

    :ok
  end
end
