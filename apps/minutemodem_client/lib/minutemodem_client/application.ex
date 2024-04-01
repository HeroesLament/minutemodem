defmodule MinuteModemClient.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # wx_mvu is already running (started as dependency)

    # Start our scenes
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.UI)
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.DTE)

    # Our own supervisor (for any non-UI processes)
    children = []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: MinuteModemClient.Supervisor
    )
  end
end
