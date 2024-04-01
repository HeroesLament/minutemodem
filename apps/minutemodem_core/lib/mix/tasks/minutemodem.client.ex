defmodule Mix.Tasks.Minutemodem.Client do
  @moduledoc """
  Starts the MinuteModem DTE client.

  ## Usage

      mix minutemodem.client

  Optionally specify host and port:

      mix minutemodem.client --host 192.168.1.100 --port 3001

  """
  use Mix.Task

  @shortdoc "Start the MinuteModem DTE client"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      strict: [host: :string, port: :integer]
    )

    # Start dependencies but not the full app (which would start the server UI)
    Application.ensure_all_started(:wx_mvu)

    # Store connection defaults if provided
    if host = opts[:host] do
      Application.put_env(:minutemodem_client, :default_host, host)
    end

    if port = opts[:port] do
      Application.put_env(:minutemodem_client, :default_port, port)
    end

    # Start client scenes
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.UI)
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.DTE)

    # Keep running
    Process.sleep(:infinity)
  end
end
