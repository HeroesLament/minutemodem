import Config

config :minutemodem_simnet,
  default_sample_rate: 9600,
  default_block_ms: 2,
  default_representation: :audio_f32,
  cluster_size: 3,
  cluster_topologies: [
    simnet: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.1"
      ]
    ]
  ]
