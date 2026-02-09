defmodule LicenseUI.Scenes.License do
  @moduledoc """
  wx_mvu scene for license key entry and activation.

  TODO: Implement once wx_mvu DSL API is finalized.
  For now this is a stub to allow the umbrella to compile.
  """

  require Logger

  def show(opts \\ []) do
    Logger.warning("LicenseUI.Scenes.License is not yet implemented — use LicenseTUI instead")
    {:error, :not_implemented}
  end
end
