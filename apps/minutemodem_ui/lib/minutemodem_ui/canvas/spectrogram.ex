defmodule MinuteModemUI.Canvas.Spectrogram do
  @moduledoc """
  Scrolling time-frequency display (waterfall).

  Receives FFT magnitude bins, adds them as new rows, scrolls older data up.
  Uses a circular buffer texture for efficient updates.

  ## Data

      WxMVU.GLCanvas.send_data(:spectrogram, {:bins, binary})
      # binary = <<mag1::float-32-little, mag2::float-32-little, ...>>
      # bins should be in dB (typically -100 to 0 dB range)

      WxMVU.GLCanvas.send_data(:spectrogram, :clear)

  ## Options

      {:ensure_gl_canvas, :spectrogram, :parent,
        module: MinuteModemUI.Canvas.Spectrogram,
        size: {600, 300},
        opts: [
          history: 256,       # number of FFT rows to display
          fft_size: 512,      # expected bins per row
          db_min: -100.0,     # floor level (dB)
          db_max: 0.0,        # ceiling level (dB)
          colormap: :viridis  # :viridis, :plasma, :hot, :grayscale
        ]}
  """

  use WxMVU.GLCanvas
  alias WxMVU.Renderer.GL
  require Logger

  @default_history 256
  @default_fft_size 512
  @default_db_min -100.0
  @default_db_max 0.0

  ## ------------------------------------------------------------------
  ## Shaders
  ## ------------------------------------------------------------------

  @vertex_shader """
  #version 410 core
  layout(location = 0) in vec2 a_position;
  layout(location = 1) in vec2 a_texcoord;
  out vec2 v_texcoord;
  void main() {
    gl_Position = vec4(a_position, 0.0, 1.0);
    v_texcoord = a_texcoord;
  }
  """

  # Fragment shader with circular buffer offset and colormap
  @fragment_shader """
  #version 410 core
  in vec2 v_texcoord;
  out vec4 frag_color;

  uniform sampler2D u_spectrogram;
  uniform sampler2D u_colormap;  // 256x1 texture used as 1D colormap
  uniform float u_row_offset;    // normalized offset for circular buffer
  uniform float u_db_min;
  uniform float u_db_max;

  void main() {
    // Apply circular buffer offset to y coordinate
    float y = mod(v_texcoord.y + u_row_offset, 1.0);
    vec2 coord = vec2(v_texcoord.x, y);

    float db = texture(u_spectrogram, coord).r;

    // Normalize dB to [0, 1]
    float normalized = clamp((db - u_db_min) / (u_db_max - u_db_min), 0.0, 1.0);

    // Sample colormap (2D texture with height=1, sample at y=0.5)
    vec3 color = texture(u_colormap, vec2(normalized, 0.5)).rgb;

    frag_color = vec4(color, 1.0);
  }
  """

  ## ------------------------------------------------------------------
  ## Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(ctx, opts) do
    history = Keyword.get(opts, :history, @default_history)
    fft_size = Keyword.get(opts, :fft_size, @default_fft_size)
    db_min = Keyword.get(opts, :db_min, @default_db_min)
    db_max = Keyword.get(opts, :db_max, @default_db_max)
    colormap_name = Keyword.get(opts, :colormap, :viridis)

    case create_program() do
      {:ok, program, uniforms} ->
        # Create VAO/VBO for fullscreen quad
        {vao, vbo} = create_quad()

        # Create spectrogram texture (width = fft_size, height = history)
        spec_tex = create_spectrogram_texture(fft_size, history, db_min)

        # Create colormap texture
        colormap_tex = create_colormap_texture(colormap_name)

        {pixel_w, pixel_h} = ctx.pixel_size
        GL.viewport(0, 0, pixel_w, pixel_h)

        {:ok,
         %{
           history: history,
           fft_size: fft_size,
           db_min: db_min,
           db_max: db_max,
           current_row: 0,
           program: program,
           uniforms: uniforms,
           vao: vao,
           vbo: vbo,
           spec_texture: spec_tex,
           colormap_texture: colormap_tex,
           pixel_size: ctx.pixel_size
         }}

      {:error, reason} ->
        Logger.error("Spectrogram: shader compilation failed: #{reason}")
        {:error, {:shader_failed, reason}}
    end
  end

  @impl true
  def handle_event(%Resize{pixel_size: {w, h}}, state) do
    GL.viewport(0, 0, w, h)
    {:noreply, %{state | pixel_size: {w, h}}}
  end

  @impl true
  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_data({:bins, binary}, state) when is_binary(binary) do
    # Upload new row to texture
    row = state.current_row
    fft_size = state.fft_size

    # Ensure binary is correct size, pad or truncate as needed
    bin_size = byte_size(binary)
    expected_size = fft_size * 4

    padded =
      cond do
        bin_size == expected_size -> binary
        bin_size < expected_size -> binary <> :binary.copy(<<state.db_min::float-32-native>>, fft_size - div(bin_size, 4))
        true -> binary_part(binary, 0, expected_size)
      end

    # Upload to current row
    GL.bind_texture(:texture_2d, state.spec_texture)
    GL.tex_sub_image_2d(0, row, fft_size, 1, :red, :float, padded)

    # Advance row pointer (circular)
    next_row = rem(row + 1, state.history)

    {:noreply, %{state | current_row: next_row}}
  end

  def handle_data(:clear, state) do
    # Clear texture to db_min
    GL.bind_texture(:texture_2d, state.spec_texture)
    empty_row = :binary.copy(<<state.db_min::float-32-native>>, state.fft_size)

    for row <- 0..(state.history - 1) do
      GL.tex_sub_image_2d(0, row, state.fft_size, 1, :red, :float, empty_row)
    end

    {:noreply, %{state | current_row: 0}}
  end

  def handle_data(_msg, state), do: {:noreply, state}

  @impl true
  def render(state) do
    GL.clear_color(0.0, 0.0, 0.0, 1.0)
    GL.clear(:color)

    GL.use_program(state.program)

    # Bind spectrogram texture
    GL.active_texture(0)
    GL.bind_texture(:texture_2d, state.spec_texture)
    GL.uniform_1i(state.uniforms.spectrogram, 0)

    # Bind colormap texture
    GL.active_texture(1)
    bind_texture_1d(state.colormap_texture)
    GL.uniform_1i(state.uniforms.colormap, 1)

    # Set uniforms
    # Row offset: newest data should appear at bottom
    # current_row points to next row to write (oldest visible)
    row_offset = state.current_row / state.history
    GL.uniform_1f(state.uniforms.row_offset, row_offset)
    GL.uniform_1f(state.uniforms.db_min, state.db_min)
    GL.uniform_1f(state.uniforms.db_max, state.db_max)

    GL.bind_vertex_array(state.vao)
    GL.draw_arrays(:triangle_strip, 0, 4)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    GL.delete_program(state.program)
    GL.delete_vertex_array(state.vao)
    GL.delete_buffer(state.vbo)
    GL.delete_texture(state.spec_texture)
    GL.delete_texture(state.colormap_texture)
    :ok
  end

  ## ------------------------------------------------------------------
  ## Private - Shader Setup
  ## ------------------------------------------------------------------

  defp create_program do
    with {:ok, vs} <- GL.create_shader(:vertex, @vertex_shader),
         {:ok, fs} <- GL.create_shader(:fragment, @fragment_shader),
         {:ok, program} <- GL.create_program(vs, fs) do
      GL.delete_shader(vs)
      GL.delete_shader(fs)

      uniforms = %{
        spectrogram: GL.get_uniform_location(program, "u_spectrogram"),
        colormap: GL.get_uniform_location(program, "u_colormap"),
        row_offset: GL.get_uniform_location(program, "u_row_offset"),
        db_min: GL.get_uniform_location(program, "u_db_min"),
        db_max: GL.get_uniform_location(program, "u_db_max")
      }

      {:ok, program, uniforms}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  ## ------------------------------------------------------------------
  ## Private - Geometry
  ## ------------------------------------------------------------------

  defp create_quad do
    vao = GL.create_vertex_array()
    vbo = GL.create_buffer()

    GL.bind_vertex_array(vao)
    GL.bind_buffer(:array, vbo)

    # Fullscreen quad: position (x, y) + texcoord (s, t)
    vertices =
      <<
        -1.0::float-32-native, -1.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
        1.0::float-32-native, -1.0::float-32-native, 1.0::float-32-native, 0.0::float-32-native,
        -1.0::float-32-native, 1.0::float-32-native, 0.0::float-32-native, 1.0::float-32-native,
        1.0::float-32-native, 1.0::float-32-native, 1.0::float-32-native, 1.0::float-32-native
      >>

    GL.buffer_data(:array, vertices, :static)

    GL.vertex_attrib_pointer(0, 2, :float, false, 16, 0)
    GL.enable_vertex_attrib_array(0)
    GL.vertex_attrib_pointer(1, 2, :float, false, 16, 8)
    GL.enable_vertex_attrib_array(1)

    GL.bind_vertex_array(0)

    {vao, vbo}
  end

  ## ------------------------------------------------------------------
  ## Private - Textures
  ## ------------------------------------------------------------------

  defp create_spectrogram_texture(fft_size, history, db_min) do
    tex = GL.create_texture()
    GL.bind_texture(:texture_2d, tex)

    # R32F texture, initialized to db_min
    empty = :binary.copy(<<db_min::float-32-native>>, fft_size * history)
    GL.tex_image_2d(fft_size, history, :r32f, :red, :float, empty)

    GL.tex_parameter(:min_filter, :linear)
    GL.tex_parameter(:mag_filter, :linear)
    GL.tex_parameter(:wrap_s, :clamp_to_edge)
    GL.tex_parameter(:wrap_t, :repeat)  # Repeat for circular buffer

    tex
  end

  defp create_colormap_texture(colormap_name) do
    colors = colormap_data(colormap_name)
    tex = GL.create_texture()

    # Use 2D texture with height=1 as 1D texture (more portable)
    GL.bind_texture(:texture_2d, tex)
    GL.tex_image_2d(256, 1, :rgb8, :rgb, :unsigned_byte, colors)

    GL.tex_parameter(:min_filter, :linear)
    GL.tex_parameter(:mag_filter, :linear)
    GL.tex_parameter(:wrap_s, :clamp_to_edge)
    GL.tex_parameter(:wrap_t, :clamp_to_edge)

    tex
  end

  # Bind 1D-style texture (actually 2D with height=1)
  defp bind_texture_1d(tex) do
    GL.bind_texture(:texture_2d, tex)
  end

  ## ------------------------------------------------------------------
  ## Private - Colormaps
  ## ------------------------------------------------------------------

  defp colormap_data(:viridis) do
    # Generate 256-entry viridis colormap
    generate_colormap([
      {0.0, {68, 1, 84}},
      {0.25, {59, 82, 139}},
      {0.5, {33, 145, 140}},
      {0.75, {94, 201, 98}},
      {1.0, {253, 231, 37}}
    ])
  end

  defp colormap_data(:plasma) do
    generate_colormap([
      {0.0, {13, 8, 135}},
      {0.25, {126, 3, 168}},
      {0.5, {204, 71, 120}},
      {0.75, {248, 149, 64}},
      {1.0, {240, 249, 33}}
    ])
  end

  defp colormap_data(:hot) do
    generate_colormap([
      {0.0, {0, 0, 0}},
      {0.33, {230, 0, 0}},
      {0.66, {255, 200, 0}},
      {1.0, {255, 255, 255}}
    ])
  end

  defp colormap_data(:grayscale) do
    generate_colormap([
      {0.0, {0, 0, 0}},
      {1.0, {255, 255, 255}}
    ])
  end

  defp colormap_data(_), do: colormap_data(:viridis)

  defp generate_colormap(stops) do
    for i <- 0..255, into: <<>> do
      t = i / 255.0
      {r, g, b} = interpolate_color(stops, t)
      <<r::8, g::8, b::8>>
    end
  end

  defp interpolate_color([{_, color}], _t), do: color

  defp interpolate_color([{t0, c0}, {t1, c1} | _rest], t) when t <= t1 do
    ratio = (t - t0) / (t1 - t0)
    lerp_color(c0, c1, ratio)
  end

  defp interpolate_color([_ | rest], t), do: interpolate_color(rest, t)

  defp lerp_color({r0, g0, b0}, {r1, g1, b1}, t) do
    {
      trunc(r0 + (r1 - r0) * t),
      trunc(g0 + (g1 - g0) * t),
      trunc(b0 + (b1 - b0) * t)
    }
  end
end
