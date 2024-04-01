defmodule MinuteModemCore.Rig.Types do
  @moduledoc """
  Rig type lookup and dispatch.
  """

  alias MinuteModemCore.Rig.Types.{Test, HF, HFRx, VHF}

  def module_for("test"), do: Test
  def module_for("hf"), do: HF
  def module_for("hf_rx"), do: HFRx
  def module_for("vhf"), do: VHF
  def module_for(_), do: Test
end
