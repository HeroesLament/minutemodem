defmodule MinuteModemClient.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # wx_mvu is already running (started as dependency)

    if LicenseCore.enabled?() and LicenseCore.check() != :ok do
      {:ok, pid} = WxMVU.start_scene(LicenseUI.Scenes.License)
      spawn(fn ->
        ref = Process.monitor(pid)
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> start_main_scenes()
        end
      end)
    else
      start_main_scenes()
    end

    Supervisor.start_link([],
      strategy: :one_for_one,
      name: MinuteModemClient.Supervisor
    )
  end

  def start_main_scenes do
    scenes = [
      MinuteModemClient.Scenes.UI,
      MinuteModemClient.Scenes.DTE
    ]

    for scene <- scenes do
      case WxMVU.start_scene(scene) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    :ok
  end
end
