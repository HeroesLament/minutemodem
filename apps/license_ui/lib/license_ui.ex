defmodule LicenseUI do
  @moduledoc """
  GUI license activation for MinuteModem.

  Provides a wx_mvu scene that checks license status and
  handles activation before proceeding to the main application.

  ## Usage in MinuteModemUI.Application

      def start(_type, _args) do
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

        Supervisor.start_link([], strategy: :one_for_one, name: MinuteModemUI.Supervisor)
      end
  """

  @doc """
  Show the license activation scene.

  The `on_success` callback is invoked after successful activation,
  typically to start the main UI scenes.
  """
  def show_activation(on_success) when is_function(on_success, 0) do
    WxMVU.start_scene({LicenseUI.Scenes.License, on_success: on_success})
  end

  @doc """
  Check license and either proceed or show activation.

  Convenience wrapper that handles the common pattern.
  """
  def gate(on_licensed) when is_function(on_licensed, 0) do
    if LicenseCore.enabled?() do
      case LicenseCore.check() do
        :ok ->
          on_licensed.()

        _ ->
          show_activation(on_licensed)
      end
    else
      on_licensed.()
    end
  end
end
