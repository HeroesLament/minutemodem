defmodule WxMVU.GLCanvas do
  @moduledoc """
  Behaviour for OpenGL canvas components.

  A GLCanvas is a managed rendering surface embedded in the wx_mvu framework.
  Unlike regular widgets, a GLCanvas:

  - Owns its GL context and render loop
  - Receives data directly (bypasses MVU diffing)
  - Renders imperatively, not declaratively

  ## Usage

  Define a module that implements the GLCanvas behaviour:

      defmodule MyApp.WaterfallCanvas do
        use WxMVU.GLCanvas

        @impl true
        def init(ctx, opts) do
          # ctx contains GL context info (version, capabilities, size)
          # Set up shaders, buffers, textures here
          {:ok, %{texture: nil, buffer: []}}
        end

        @impl true
        def handle_event(%Resize{pixel_size: {w, h}}, state) do
          # Resize textures, update projection, etc.
          {:noreply, state}
        end

        @impl true
        def handle_event(_event, state) do
          {:noreply, state}
        end

        @impl true
        def handle_data({:fft_bins, bins}, state) do
          # Buffer incoming FFT data
          {:noreply, %{state | buffer: [bins | state.buffer]}}
        end

        @impl true
        def render(state) do
          # Draw frame using WxMVU.GLCanvas.Draw API
          {:noreply, state}
        end

        @impl true
        def terminate(_reason, state) do
          # Clean up GL resources
          :ok
        end
      end

  Add to a scene's view:

      def view(model) do
        [
          {:ensure_window, :main, title: "Spectrum"},
          {:ensure_panel, :root, :main, []},
          {:ensure_gl_canvas, :waterfall, :root,
            module: MyApp.WaterfallCanvas,
            size: {800, 400},
            opts: [fft_size: 2048]
          },
          {:refresh, :main}
        ]
      end

  Send data directly to the canvas:

      WxMVU.GLCanvas.send_data(:waterfall, {:fft_bins, bins})

  ## Lifecycle

  1. Renderer creates wxGLCanvas and starts GLCanvas.Server
  2. Server creates GL context and calls `init/2`
  3. Server schedules render ticks
  4. On each tick, `render/1` is called with context current
  5. Resize events delivered via `handle_event/2`
  6. Data delivered via `handle_data/2`
  7. On shutdown, `terminate/2` called with context still valid

  ## Important Invariants

  - GL context is runtime-owned; callbacks assume it's current
  - Resize is an event, not a re-render trigger
  - Canvas authors never call raw :gl functions
  - Canvas authors never see GL constants
  """

  # ============================================================================
  # Context
  # ============================================================================

  defmodule Context do
    @moduledoc """
    Opaque GL context passed to canvas callbacks.

    Contains information about the GL environment but does not expose
    the raw context handle. Canvas authors use this for capability
    queries and size information.
    """

    @type t :: %__MODULE__{
            gl_version: {major :: integer(), minor :: integer()},
            glsl_version: String.t(),
            profile: :core | :compatibility,
            pixel_size: {width :: integer(), height :: integer()},
            logical_size: {width :: integer(), height :: integer()},
            dpi_scale: float(),
            capabilities: map()
          }

    defstruct [
      :gl_version,
      :glsl_version,
      :profile,
      :pixel_size,
      :logical_size,
      :dpi_scale,
      :capabilities
    ]
  end

  # ============================================================================
  # Events
  # ============================================================================

  defmodule Event do
    @moduledoc """
    Events delivered to GLCanvas via `handle_event/2`.
    """

    defmodule Resize do
      @moduledoc """
      Delivered when the canvas is resized.

      - `logical_size` - Size in wx/logical units
      - `pixel_size` - Actual framebuffer size in pixels
      - `dpi_scale` - Ratio of pixel to logical (for HiDPI)

      Always use `pixel_size` for GL viewport and texture dimensions.
      """

      @type t :: %__MODULE__{
              logical_size: {width :: integer(), height :: integer()},
              pixel_size: {width :: integer(), height :: integer()},
              dpi_scale: float()
            }

      defstruct [:logical_size, :pixel_size, :dpi_scale]
    end

    defmodule Mouse do
      @moduledoc """
      Mouse events within the canvas.
      """

      @type event_type :: :move | :down | :up | :enter | :leave | :wheel

      @type t :: %__MODULE__{
              type: event_type(),
              x: integer(),
              y: integer(),
              button: :left | :middle | :right | nil,
              wheel_delta: integer() | nil,
              modifiers: [modifier()]
            }

      @type modifier :: :shift | :ctrl | :alt | :meta

      defstruct [:type, :x, :y, :button, :wheel_delta, modifiers: []]
    end

    defmodule Key do
      @moduledoc """
      Keyboard events when canvas has focus.
      """

      @type event_type :: :down | :up

      @type t :: %__MODULE__{
              type: event_type(),
              key: integer(),
              char: String.t() | nil,
              modifiers: [Mouse.modifier()]
            }

      defstruct [:type, :key, :char, modifiers: []]
    end

    defmodule Focus do
      @moduledoc """
      Focus gained/lost events.
      """

      @type t :: %__MODULE__{
              type: :gained | :lost
            }

      defstruct [:type]
    end
  end

  # ============================================================================
  # Behaviour
  # ============================================================================

  @type state :: term()
  @type event ::
          Event.Resize.t()
          | Event.Mouse.t()
          | Event.Key.t()
          | Event.Focus.t()

  @doc """
  Called when the canvas is initialized.

  The GL context is current and ready for resource creation.
  Create shaders, buffers, textures, and other GL resources here.

  ## Arguments

  - `ctx` - GL context information (version, capabilities, initial size)
  - `opts` - Options passed from the scene's `:ensure_gl_canvas` intent

  ## Returns

  - `{:ok, state}` - Success with initial state
  - `{:error, reason}` - Initialization failed
  """
  @callback init(ctx :: Context.t(), opts :: keyword()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Called when an event occurs (resize, mouse, keyboard, focus).

  Resize events are critical - update viewport, recreate size-dependent
  resources, and recalculate projections here.

  ## Returns

  - `{:noreply, state}` - Continue with updated state
  """
  @callback handle_event(event(), state()) :: {:noreply, state()}

  @doc """
  Called when data is sent to this canvas.

  Data bypasses MVU entirely and arrives directly here.
  Typical use: buffer incoming samples, update textures.

  ## Returns

  - `{:noreply, state}` - Continue with updated state
  """
  @callback handle_data(msg :: term(), state()) :: {:noreply, state()}

  @doc """
  Called each render frame.

  The GL context is current. Draw your frame here.
  Do not allocate large resources in render - do that in init or handle_event.

  ## Returns

  - `{:noreply, state}` - Continue with updated state
  """
  @callback render(state()) :: {:noreply, state()}

  @doc """
  Called when the canvas is being destroyed.

  The GL context is still valid. Clean up GL resources here.
  """
  @callback terminate(reason :: term(), state()) :: term()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Sends data directly to a canvas process.

  This bypasses MVU diffing entirely - data goes straight to `handle_data/2`.

  ## Examples

      WxMVU.GLCanvas.send_data(:waterfall, {:fft_bins, bins})
      WxMVU.GLCanvas.send_data(:scope, {:samples, samples})

  """
  @spec send_data(canvas_id :: term(), msg :: term()) :: :ok
  def send_data(canvas_id, msg) do
    case WxMVU.Renderer.ComponentRegistry.lookup({:gl_canvas, canvas_id}) do
      nil ->
        require Logger
        Logger.warning("GLCanvas.send_data: no canvas registered with id #{inspect(canvas_id)}")
        :ok

      pid ->
        send(pid, {:gl_data, msg})
        :ok
    end
  end

  @doc """
  Requests an immediate render frame.

  Normally the runtime schedules renders. Use this to force a redraw
  after data updates if needed.
  """
  @spec request_render(canvas_id :: term()) :: :ok
  def request_render(canvas_id) do
    case WxMVU.Renderer.ComponentRegistry.lookup({:gl_canvas, canvas_id}) do
      nil -> :ok
      pid -> send(pid, :request_render)
    end

    :ok
  end

  # ============================================================================
  # __using__ macro
  # ============================================================================

  defmacro __using__(_opts) do
    quote do
      @behaviour WxMVU.GLCanvas

      alias WxMVU.GLCanvas.Context
      alias WxMVU.GLCanvas.Event
      alias WxMVU.GLCanvas.Event.{Resize, Mouse, Key, Focus}

      # Default implementations
      @impl true
      def handle_event(_event, state), do: {:noreply, state}

      @impl true
      def handle_data(_msg, state), do: {:noreply, state}

      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable handle_event: 2, handle_data: 2, terminate: 2
    end
  end
end
