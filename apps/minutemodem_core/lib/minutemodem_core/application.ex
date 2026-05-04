defmodule MinuteModemCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :pg.start_link(:minutemodem_pg)

    # Redirect this process's group leader to the iex shell (if any) so
    # output from `LicenseTUI.Gate.require_license!/0` (Owl-rendered
    # selection prompts) ends up in the user's terminal rather than the
    # release log.
    redirect_to_iex_shell()

    # Synchronous license check before starting any supervised children.
    # Ensures the entire app is gated on a valid license without splitting
    # startup into phases that race with the UI app's launch.
    LicenseTUI.Gate.require_license!()

    children = [
      MinuteModemCore.Persistence.Repo,
      # Ecto.Migrator runs all pending migrations synchronously on startup.
      # Placed immediately after the Repo so anything below this line is
      # guaranteed to see a fully-migrated schema. Skippable via the
      # SKIP_MIGRATIONS env var.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:minutemodem_core, :ecto_repos),
       skip: System.get_env("SKIP_MIGRATIONS") == "true"},
      {Registry, keys: :unique, name: MinuteModemCore.Rig.InstanceRegistry},
      {Registry, keys: :unique, name: MinuteModemCore.Modem.Registry},
      {Registry, keys: :unique, name: MinuteModemCore.Interface.Registry},
      MinuteModemCore.Settings.Manager,
      MinuteModemCore.Audio.Manager,
      MinuteModemCore.Audio.Pipeline,
      MinuteModemCore.Control.Router,
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

  @doc """
  Best-effort: find the iex shell process by walking process dictionaries
  and looking for the `:shell` key. Returns the pid or nil if not found.
  """
  def find_iex_gl do
    Process.list()
    |> Enum.find_value(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          if Keyword.has_key?(dict, :shell), do: pid

        _ ->
          nil
      end
    end)
  end

  defp redirect_to_iex_shell(attempts \\ 50)
  defp redirect_to_iex_shell(0), do: :ok

  defp redirect_to_iex_shell(attempts) do
    case find_iex_gl() do
      nil ->
        Process.sleep(100)
        redirect_to_iex_shell(attempts - 1)

      gl ->
        Process.group_leader(self(), gl)
        :ok
    end
  end
end
