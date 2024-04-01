defmodule Mix.Tasks.Minutemodem.Server do
  @moduledoc """
  Starts the MinuteModem server with UI.

  ## Usage

      mix minutemodem.server

  """
  use Mix.Task

  @shortdoc "Start the MinuteModem server with UI"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    # Keep running
    Process.sleep(:infinity)
  end
end
