defmodule MinuteModemCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Start pg scope for pubsub
    :pg.start_link(:minutemodem_pg)

    children = [
      # Persistence
      MinuteModemCore.Persistence.Repo,

      # Process registries
      {Registry, keys: :unique, name: MinuteModemCore.Rig.InstanceRegistry},
      {Registry, keys: :unique, name: MinuteModemCore.Modem.Registry},
      {Registry, keys: :unique, name: MinuteModemCore.Interface.Registry},

      # Settings subsystem
      MinuteModemCore.Settings.Manager,

      # Audio subsystem
      MinuteModemCore.Audio.Manager,
      MinuteModemCore.Audio.Pipeline,

      # Control plane
      MinuteModemCore.Control.Router,

      # Rig management
      MinuteModemCore.Rig.Registry,
      {DynamicSupervisor,
       name: MinuteModemCore.Rig.Supervisor,
       strategy: :one_for_one}
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: MinuteModemCore.Supervisor
    )
  end
end
