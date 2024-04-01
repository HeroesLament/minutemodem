defmodule WxMVU.Application do
  @moduledoc """
  OTP Application for wx_mvu.

  Starts the supervision tree containing:
  - Renderer (owns wx environment)
  - ComponentRegistry (maps widget_id -> scene pid)
  - Coordinator (batches and diffs intents)
  - SceneSupervisor (DynamicSupervisor for scene processes)
  - GLCanvas.Registry (process registry for GL canvases)
  - GLCanvasSupervisor (DynamicSupervisor for GL canvas processes)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Core registries
      WxMVU.Renderer.ComponentRegistry,
      {Registry, keys: :unique, name: WxMVU.GLCanvas.Registry},

      # Renderer - owns wx environment
      WxMVU.Renderer,

      # Coordinator - batches and diffs intents
      WxMVU.Coordinator,

      # Dynamic supervisors for scenes and canvases
      {DynamicSupervisor, name: WxMVU.SceneSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: WxMVU.GLCanvasSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: WxMVU.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
