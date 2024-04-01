# lib/eparl/application.ex
defmodule Eparl.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Don't start automatically - let the user start with Eparl.start_link/1
    # This allows them to configure command_module, initial_state, etc.
    Supervisor.start_link([], strategy: :one_for_one, name: Eparl.ApplicationSupervisor)
  end
end
