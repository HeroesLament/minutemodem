defmodule MinuteModemCore.Persistence.Rigs do
  @moduledoc """
  Persistence API for radio rigs.
  """

  alias MinuteModemCore.Persistence.Repo
  alias MinuteModemCore.Persistence.Schemas.Rig

  def list_rigs do
    Repo.all(Rig)
  end

  def get_rig!(id) do
    Repo.get!(Rig, id)
  end

  def create_rig(attrs) do
    %Rig{}
    |> Rig.changeset(attrs)
    |> Repo.insert()
  end

  def update_rig(%Rig{} = rig, attrs) do
    rig
    |> Rig.changeset(attrs)
    |> Repo.update()
  end

  def delete_rig(%Rig{} = rig) do
    Repo.delete(rig)
  end
end
