defmodule MinuteModemCore.Release do
  @moduledoc """
  Release-time helpers for MinuteModemCore.

  Used by `MinuteModemCore.Application` to ensure the database schema is
  up-to-date before any GenServers start querying it. Also exposed for
  manual invocation from `bin/minutemodem_station eval`:

      bin/minutemodem_station eval "MinuteModemCore.Release.migrate()"
  """

  require Logger

  @app :minutemodem_core

  @doc """
  Run any pending Ecto migrations for all configured repos.

  Idempotent — safe to call on every boot. No-op when the database is
  already up-to-date.

  Implementation notes:
  - Uses `Ecto.Migrator.with_repo` which starts a temporary Repo connection
    for the migration, runs migrations, then tears down. The long-lived
    Repo started later by the supervision tree picks up the already-
    migrated schema.
  - Passes an explicit migrations path computed via `Application.app_dir/2`
    so it works correctly inside a release (where the cwd is not the
    project root).
  """
  def migrate do
    load_app()

    for repo <- repos() do
      path = Application.app_dir(@app, "priv/repo/migrations")
      Logger.info("Running pending migrations for #{inspect(repo)} from #{path}")

      case File.ls(path) do
        {:ok, files} ->
          Logger.info("Migration files found: #{inspect(files)}")

        {:error, reason} ->
          Logger.error("Migration directory not accessible: #{inspect(reason)}")
      end

      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, path, :up, all: true)
        end)

      Logger.info("Migrations complete for #{inspect(repo)}")
    end

    :ok
  end

  @doc """
  Roll back the given repo to a specific migration version.
  """
  def rollback(repo, version) do
    load_app()
    path = Application.app_dir(@app, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, path, :down, to: version)
      end)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
