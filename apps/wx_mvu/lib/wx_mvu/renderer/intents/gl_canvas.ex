defmodule WxMVU.Renderer.Intents.GLCanvas do
  @moduledoc false
  # Intent handler for GL canvas widgets.
  #
  # Creates wxGLCanvas, starts GLCanvas.Server, wires events.

  use WxEx
  require Logger

  alias WxMVU.GLCanvas.Server, as: GLCanvasServer

  # GL attributes for modern OpenGL core profile
  # On macOS, we need to explicitly request 4.1 core profile to avoid getting legacy 2.1
  @gl_attribs [
    1,      # WX_GL_RGBA
    4,      # WX_GL_DOUBLEBUFFER
    11, 24, # WX_GL_DEPTH_SIZE, 24
    12, 8,  # WX_GL_STENCIL_SIZE, 8
    20,     # WX_GL_CORE_PROFILE
    21, 4,  # WX_GL_MAJOR_VERSION, 4
    22, 1,  # WX_GL_MINOR_VERSION, 1
    0       # terminator
  ]

  def apply({:ensure_gl_canvas, canvas_id, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, {:gl_canvas, canvas_id}) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for gl_canvas #{inspect(canvas_id)}")
        state
      else
        module = Keyword.fetch!(opts, :module)
        size = Keyword.get(opts, :size, {640, 480})
        user_opts = Keyword.get(opts, :opts, [])
        fps = Keyword.get(opts, :fps, 60)

        # Create wxGLCanvas
        wx_canvas = create_gl_canvas(parent, size)

        # Add to parent sizer
        parent_sizer = Map.get(state.sizers, parent_id)

        if parent_sizer do
          :wxSizer.add(
            parent_sizer,
            wx_canvas,
            proportion: 1,
            flag: Bitwise.bor(wxEXPAND(), wxALL()),
            border: 0
          )
        end

        # Connect wx events - we'll translate and forward to the server
        :wxEvtHandler.connect(wx_canvas, :size)
        :wxEvtHandler.connect(wx_canvas, :paint, skip: true)
        :wxEvtHandler.connect(wx_canvas, :motion)
        :wxEvtHandler.connect(wx_canvas, :left_down)
        :wxEvtHandler.connect(wx_canvas, :left_up)
        :wxEvtHandler.connect(wx_canvas, :middle_down)
        :wxEvtHandler.connect(wx_canvas, :middle_up)
        :wxEvtHandler.connect(wx_canvas, :right_down)
        :wxEvtHandler.connect(wx_canvas, :right_up)
        :wxEvtHandler.connect(wx_canvas, :mousewheel)
        :wxEvtHandler.connect(wx_canvas, :enter_window)
        :wxEvtHandler.connect(wx_canvas, :leave_window)
        :wxEvtHandler.connect(wx_canvas, :key_down)
        :wxEvtHandler.connect(wx_canvas, :key_up)
        :wxEvtHandler.connect(wx_canvas, :set_focus)
        :wxEvtHandler.connect(wx_canvas, :kill_focus)

        # Start GLCanvas.Server under supervisor
        # Pass wx env so the server process can use wx
        wx_env = :wx.get_env()

        server_opts = [
          id: canvas_id,
          module: module,
          wx_canvas: wx_canvas,
          wx_env: wx_env,
          opts: user_opts,
          fps: fps
        ]

        case DynamicSupervisor.start_child(WxMVU.GLCanvasSupervisor, {GLCanvasServer, server_opts}) do
          {:ok, _pid} ->
            Logger.debug("Renderer: started GLCanvas.Server for #{inspect(canvas_id)}")

          {:error, reason} ->
            Logger.error("Renderer: failed to start GLCanvas.Server for #{inspect(canvas_id)}: #{inspect(reason)}")
        end

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, {:gl_canvas, canvas_id}, wx_canvas),
            widget_ids: Map.put(state.widget_ids, wx_canvas, {:gl_canvas, canvas_id})
        }
      end
    end
  end

  def apply({:destroy_gl_canvas, canvas_id}, state) do
    case Map.get(state.widgets, {:gl_canvas, canvas_id}) do
      nil ->
        state

      wx_canvas ->
        # Stop the server
        GLCanvasServer.stop(canvas_id)

        # Destroy wx widget
        :wxWindow.destroy(wx_canvas)

        %{
          state
          | widgets: Map.delete(state.widgets, {:gl_canvas, canvas_id}),
            widget_ids: Map.delete(state.widget_ids, wx_canvas)
        }
    end
  end

  defp create_gl_canvas(parent, {width, height}) do
    # Create with GL attributes for modern OpenGL
    :wxGLCanvas.new(
      parent,
      [
        size: {width, height},
        attribList: @gl_attribs,
        style: wxFULL_REPAINT_ON_RESIZE()
      ]
    )
  end
end
