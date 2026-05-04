defmodule MinutemodemSimnet.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MinutemodemSimnet.Telemetry,
      # Cluster discovery
      {Cluster.Supervisor, [topologies(), [name: MinutemodemSimnet.ClusterSupervisor]]},
      # eParl consensus layer
      %{
        id: Eparl,
        start: {Eparl, :start_link, [[
          command_module: MinutemodemSimnet.KVS,
          cluster_size: cluster_size(),
          initial_state: %{}
        ]]}
      },
      # pg scope for tick distribution
      %{id: :simnet_pg, start: {:pg, :start_link, [:simnet_pg]}},
      # RX subscription registry
      MinutemodemSimnet.Routing.RxRegistry,
      # Horde distributed supervision for RxCombiners
      MinutemodemSimnet.RxCombiner.Registry,
      MinutemodemSimnet.RxCombiner.Supervisor,
      # Router (stateless fan-out)
      MinutemodemSimnet.Routing.Router,
      # Rig attachment lifecycle (serialized GenServer)
      MinutemodemSimnet.Rig.Attachment,
      # Highlander singleton control server
      MinutemodemSimnet.Control.Supervisor
    ]

    opts = [strategy: :one_for_one, name: MinutemodemSimnet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp topologies do
    Application.get_env(:minutemodem_simnet, :cluster_topologies, default_topologies())
  end

  defp default_topologies do
    [
      simnet: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "230.1.1.1"
        ]
      ]
    ]
  end

  defp cluster_size do
    Application.get_env(:minutemodem_simnet, :cluster_size, 1)
  end
end
