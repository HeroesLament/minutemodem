defmodule MinuteModemCore.Persistence.Callsigns do
  @moduledoc """
  Persistence API for station directory and LQA soundings.
  """

  import Ecto.Query

  alias MinuteModemCore.Persistence.Repo
  alias MinuteModemCore.Persistence.Schemas.Callsign
  alias MinuteModemCore.Persistence.Schemas.LqaSounding

  @max_soundings_per_callsign 2000

  ## ------------------------------------------------------------------
  ## Callsign CRUD
  ## ------------------------------------------------------------------

  def list_callsigns do
    Repo.all(from c in Callsign, order_by: [desc: c.last_heard])
  end

  def list_callsigns_by_source(source) do
    Repo.all(from c in Callsign, where: c.source == ^source, order_by: [desc: c.last_heard])
  end

  def get_callsign(id) do
    Repo.get(Callsign, id)
  end

  def get_callsign!(id) do
    Repo.get!(Callsign, id)
  end

  def get_callsign_by_addr(addr) do
    Repo.get_by(Callsign, addr: addr)
  end

  def create_callsign(attrs) do
    %Callsign{}
    |> Callsign.changeset(attrs)
    |> Repo.insert()
  end

  def update_callsign(%Callsign{} = callsign, attrs) do
    callsign
    |> Callsign.changeset(attrs)
    |> Repo.update()
  end

  def delete_callsign(%Callsign{} = callsign) do
    Repo.delete(callsign)
  end

  @doc """
  Find or create a callsign entry, updating heard timestamps.
  Used when receiving frames from a station.
  """
  def find_or_create_heard(addr, source \\ "sounding", extra_attrs \\ %{}) do
    now = DateTime.utc_now()

    case get_callsign_by_addr(addr) do
      nil ->
        attrs = Map.merge(extra_attrs, %{
          addr: addr,
          source: source,
          first_heard: now,
          last_heard: now,
          heard_count: 1
        })
        create_callsign(attrs)

      callsign ->
        update_callsign(callsign, %{
          last_heard: now,
          heard_count: (callsign.heard_count || 0) + 1
        })
    end
  end

  ## ------------------------------------------------------------------
  ## LQA Soundings
  ## ------------------------------------------------------------------

  def list_soundings(callsign_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.all(
      from s in LqaSounding,
        where: s.callsign_id == ^callsign_id,
        order_by: [desc: s.timestamp],
        limit: ^limit
    )
  end

  def list_recent_soundings(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.all(
      from s in LqaSounding,
        where: s.timestamp > ^cutoff,
        order_by: [desc: s.timestamp],
        limit: ^limit,
        preload: [:callsign]
    )
  end

  def create_sounding(attrs) do
    result =
      %LqaSounding{}
      |> LqaSounding.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, sounding} ->
        prune_old_soundings(sounding.callsign_id)
        {:ok, sounding}

      error ->
        error
    end
  end

  @doc """
  Record a sounding and update the callsign's heard status.
  This is the main entry point for the ALE receiver.
  """
  def record_sounding(addr, freq_hz, opts \\ []) do
    source = Keyword.get(opts, :source, "sounding")
    frame_type = Keyword.get(opts, :frame_type, "sounding")

    Repo.transaction(fn ->
      {:ok, callsign} = find_or_create_heard(addr, source)

      {:ok, sounding} = create_sounding(%{
        callsign_id: callsign.id,
        timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
        freq_hz: freq_hz,
        snr_db: Keyword.get(opts, :snr_db),
        ber: Keyword.get(opts, :ber),
        sinad_db: Keyword.get(opts, :sinad_db),
        rig_id: Keyword.get(opts, :rig_id),
        net_id: Keyword.get(opts, :net_id),
        direction: Keyword.get(opts, :direction, "rx"),
        frame_type: frame_type,
        extra: Keyword.get(opts, :extra, %{})
      })

      {callsign, sounding}
    end)
  end

  @doc """
  Get LQA statistics for a callsign.
  """
  def lqa_stats(callsign_id, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.one(
      from s in LqaSounding,
        where: s.callsign_id == ^callsign_id and s.timestamp > ^cutoff,
        select: %{
          count: count(s.id),
          avg_snr: avg(s.snr_db),
          min_snr: min(s.snr_db),
          max_snr: max(s.snr_db),
          avg_ber: avg(s.ber)
        }
    )
  end

  @doc """
  Get frequency distribution for a callsign.
  """
  def frequency_stats(callsign_id, opts \\ []) do
    hours = Keyword.get(opts, :hours, 168)  # Default: 1 week
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.all(
      from s in LqaSounding,
        where: s.callsign_id == ^callsign_id and s.timestamp > ^cutoff,
        group_by: s.freq_hz,
        select: %{
          freq_hz: s.freq_hz,
          count: count(s.id),
          avg_snr: avg(s.snr_db),
          last_heard: max(s.timestamp)
        },
        order_by: [desc: count(s.id)]
    )
  end

  ## ------------------------------------------------------------------
  ## Pruning
  ## ------------------------------------------------------------------

  defp prune_old_soundings(callsign_id) do
    # Get IDs of soundings to keep (most recent N)
    keep_ids =
      Repo.all(
        from s in LqaSounding,
          where: s.callsign_id == ^callsign_id,
          order_by: [desc: s.timestamp],
          limit: @max_soundings_per_callsign,
          select: s.id
      )

    # Delete everything else for this callsign
    if length(keep_ids) >= @max_soundings_per_callsign do
      Repo.delete_all(
        from s in LqaSounding,
          where: s.callsign_id == ^callsign_id and s.id not in ^keep_ids
      )
    end

    :ok
  end

  @doc """
  Prune all callsigns to max soundings. Run periodically for maintenance.
  """
  def prune_all_soundings do
    callsign_ids = Repo.all(from c in Callsign, select: c.id)
    Enum.each(callsign_ids, &prune_old_soundings/1)
    :ok
  end
end
