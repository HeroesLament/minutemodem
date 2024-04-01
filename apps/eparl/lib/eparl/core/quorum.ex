# core/quorum.ex
defmodule Eparl.Core.Quorum do
  @moduledoc """
  Quorum calculations for ePaxos.

  Fast path requires floor(3N/4) + 1 matching responses.
  Slow path requires floor(N/2) + 1 responses.
  """

  @doc """
  Size of a fast path quorum. Requires 3/4 of replicas to agree.
  """
  def fast_quorum_size(n) when n > 0 do
    floor(3 * n / 4) + 1
  end

  @doc """
  Size of a slow path quorum. Simple majority.
  """
  def slow_quorum_size(n) when n > 0 do
    floor(n / 2) + 1
  end

  @doc """
  Check if we have enough matching responses for fast path.
  """
  def has_fast_quorum?(responses, cluster_size) do
    length(responses) >= fast_quorum_size(cluster_size)
  end

  @doc """
  Check if we have enough responses for slow path.
  """
  def has_slow_quorum?(responses, cluster_size) do
    length(responses) >= slow_quorum_size(cluster_size)
  end
end
