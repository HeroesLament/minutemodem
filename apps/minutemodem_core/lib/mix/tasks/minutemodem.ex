defmodule Mix.Tasks.Minutemodem do
  @moduledoc """
  MinuteModem commands.

  ## Usage

      mix minutemodem.server    # Start the modem server with UI
      mix minutemodem.client    # Start the DTE test client

  """
  use Mix.Task

  @shortdoc "Show MinuteModem commands"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("""
    MinuteModem commands:

      mix minutemodem.server    Start the modem server with UI
      mix minutemodem.client    Start the DTE test client

    Options for client:
      --host HOST    Connect to specific host (default: 127.0.0.1)
      --port PORT    Connect to specific port (default: 3000)
    """)
  end
end
