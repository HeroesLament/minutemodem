defmodule WxMVU.Scene do
  @moduledoc """
  Behaviour and macro for defining wx_mvu scenes.

  A scene is a self-contained unit with:
  - State (model)
  - Event handling
  - View rendering (intents)

  ## Usage

      defmodule MyApp.Scenes.Counter do
        use WxMVU.Scene

        def init(_opts) do
          %{count: 0}
        end

        def handle_event({:ui_event, :increment, :click}, model) do
          %{model | count: model.count + 1}
        end

        def handle_event(_event, model), do: model

        def view(model) do
          [
            {:ensure_window, :main, title: "Counter"},
            {:ensure_panel, :root, :main, []},
            {:ensure_widget, :label, :static_text, :root, label: "Count: \#{model.count}"},
            {:ensure_widget, :increment, :button, :root, label: "+1"},
            {:layout, :root, {:vbox, [], [:label, :increment]}},
            {:refresh, :main}
          ]
        end
      end

  ## Callbacks

  - `init/1` - Called with args from `WxMVU.start_scene/2`. Returns initial model.
  - `handle_event/2` - Called with event and current model. Returns updated model.
  - `view/1` - Called with current model. Returns list of intents.

  """

  @doc """
  Initialize the scene's model.

  Called once when the scene starts. The `args` are passed from
  `WxMVU.start_scene(Module, args: ...)`.
  """
  @callback init(args :: term()) :: model :: term()

  @doc """
  Handle an event and return the updated model.

  Events include:
  - `{:ui_event, widget_id, event_type}` - UI events (click, etc.)
  - `{:ui_event, widget_id, event_type, data}` - UI events with data (change, etc.)

  Return the model unchanged to ignore an event.
  """
  @callback handle_event(event :: term(), model :: term()) :: model :: term()

  @doc """
  Render the model as a list of intents.

  Called after every state change. Should be a pure function of the model.
  """
  @callback view(model :: term()) :: [WxMVU.Intent.t()]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour WxMVU.Scene
    end
  end
end
