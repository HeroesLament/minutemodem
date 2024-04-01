defmodule WxMVU.Theme do
  @moduledoc """
  Behaviour for defining application color themes.

  ## Usage

      defmodule MyApp.Theme do
        @behaviour WxMVU.Theme

        @impl true
        def palette(:dark) do
          %{
            background: {30, 30, 32},
            surface: {45, 45, 48},
            card: {55, 55, 58},
            text: {240, 240, 240},
            primary: {100, 140, 230}
          }
        end

        def palette(:light) do
          %{
            background: {255, 255, 255},
            surface: {245, 245, 245},
            card: {235, 235, 235},
            text: {20, 20, 20},
            primary: {60, 100, 200}
          }
        end
      end

  Then wire it up:

      defmodule MyApp.AppState do
        use WxMVU.AppState,
          scenes: [...],
          theme: MyApp.Theme
      end
  """

  @type mode :: :dark | :light
  @type color :: {0..255, 0..255, 0..255}
  @type palette :: %{atom() => color()}

  @callback palette(mode()) :: palette()

  @doc """
  Returns the default palette for apps that don't define a theme.
  """
  def palette(:dark) do
    %{
      background: {30, 30, 32},
      surface: {42, 42, 45},
      card: {52, 52, 56},
      text: {230, 230, 230},
      text_muted: {150, 150, 150},
      primary: {90, 130, 220},
      success: {80, 180, 100},
      warning: {220, 180, 60},
      error: {220, 80, 80}
    }
  end

  def palette(:light) do
    %{
      background: {255, 255, 255},
      surface: {245, 245, 247},
      card: {232, 232, 236},
      text: {20, 20, 20},
      text_muted: {100, 100, 100},
      primary: {60, 100, 200},
      success: {40, 160, 70},
      warning: {200, 160, 30},
      error: {200, 50, 50}
    }
  end
end
