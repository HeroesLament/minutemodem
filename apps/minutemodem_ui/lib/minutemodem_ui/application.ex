defmodule MinuteModemUI.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # pg scope :minutemodem_pg is started by MinuteModemCore.Application.
    # OTP guarantees minutemodem_core is fully started before us via the
    # dep declaration in mix.exs.

    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one, name: MinuteModemUI.Supervisor)

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

    {:ok, sup}
  end

  def start_main_scenes do
    scenes = [
      MinuteModemUI.Scenes.UI,
      MinuteModemUI.Scenes.Rigs,
      MinuteModemUI.Scenes.Nets,
      MinuteModemUI.Scenes.Callsigns,
      MinuteModemUI.Scenes.Config,
      MinuteModemUI.Scenes.Ops,
      MinuteModemUI.Scenes.Voice
    ]

    for scene <- scenes do
      case WxMVU.start_scene(scene) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    :ok
  end

  def reload do
    WxMVU.stop_scene(MinuteModemUI.Scenes.Voice)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Ops)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Callsigns)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Nets)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Rigs)
    WxMVU.stop_scene(MinuteModemUI.Scenes.Config)
    WxMVU.stop_scene(MinuteModemUI.Scenes.UI)
    start_main_scenes()
  end
end
