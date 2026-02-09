defmodule LicenseUI do
  @moduledoc """
  GUI license activation scene for MinuteModem.

  Provides a wx_mvu scene that prompts for a license key,
  validates it, and then calls a callback to proceed to the main application.

  ## Usage

  In your Application.start/2:

      if LicenseCore.enabled?() do
        case LicenseCore.check() do
          :ok ->
            start_main_scenes()

          _ ->
            LicenseUI.show_activation(fn -> start_main_scenes() end)
        end
      else
        start_main_scenes()
      end

  """

  @doc """
  Show the license activation scene.
  The `on_success` callback is invoked (with the license struct)
  after successful activation, typically to start the main UI scenes.
  """
  def show_activation(on_success) when is_function(on_success, 0) do
    {:ok, _} = WxMVU.start_scene({LicenseUI.Scenes.License, on_success: on_success})
  end
end
