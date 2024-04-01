# boundaries/membership.ex
defmodule Eparl.Boundaries.Membership do
  @moduledoc """
  Cluster membership via :pg (process groups).

  Each replica joins the :eparl group on startup.
  """

  @scope :eparl
  @group :replicas

  @doc """
  Start the pg scope. Called by supervisor.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link do
    :pg.start_link(@scope)
  end

  @doc """
  Join this replica to the cluster.
  """
  def join(pid) do
    :pg.join(@scope, @group, pid)
  end

  @doc """
  Leave the cluster.
  """
  def leave(pid) do
    :pg.leave(@scope, @group, pid)
  end

  @doc """
  Get all replica pids in the cluster.
  """
  def replicas do
    :pg.get_members(@scope, @group)
  end

  @doc """
  Get replica pids on other nodes (excludes local).
  """
  def remote_replicas do
    :pg.get_members(@scope, @group) -- :pg.get_local_members(@scope, @group)
  end

  @doc """
  Get local replica pid(s).
  """
  def local_replicas do
    :pg.get_local_members(@scope, @group)
  end

  @doc """
  Number of replicas in the cluster.
  """
  def cluster_size do
    length(replicas())
  end
end
