import Config

config :minutemodem_ui,
  role: :ui,
  enabled: true,
  wx: [
    title: "MinuteModem",
    width: 1024,
    height: 768
  ]

config :logger,
  level: :debug
