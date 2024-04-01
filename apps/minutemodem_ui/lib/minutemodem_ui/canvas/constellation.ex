defmodule MinuteModemUI.Canvas.Constellation do
  @moduledoc """
  I/Q constellation display with density histogram.

  Accumulates sample positions into a 2D histogram and renders as a heatmap.
  Includes decay so older data fades, showing temporal patterns.

  ## Data

      WxMVU.GLCanvas.send_data(:constellation, {:samples, binary})
      # binary = <<i1::float-32-little, q1::float-32-little, ...>>

      WxMVU.GLCanvas.send_data(:constellation, :clear)

  Samples should be normalized to approximately [-1, 1] range.

  ## Options

      {:ensure_gl_canvas, :constellation, :parent,
        module: MinuteModemUI.Canvas.Constellation,
        size: {300, 300},
        opts: [
          resolution: 128,     # histogram bins per axis
          decay: 0.98,         # per-frame decay (0.95 = fast, 0.99 = slow)
          colormap: :viridis   # :viridis, :plasma, :hot, :green
        ]}
  """

  use WxMVU.GLCanvas
  alias WxMVU.Renderer.GL
  require Logger

  @default_resolution 128
  @default_decay 0.98

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

  @fragment_shader """
  #version 410 core
  in vec2 v_texcoord;
  out vec4 frag_color;

  uniform sampler2D u_histogram;
  uniform float u_max_value;
  uniform vec3 u_color_low;
  uniform vec3 u_color_high;

  void main() {
    float density = texture(u_histogram, v_texcoord).r;
    float normalized = clamp(density / max(u_max_value, 0.001), 0.0, 1.0);

    // Gamma correction for better visibility of low values
    normalized = pow(normalized, 0.4);

    // Simple two-color gradient
    vec3 color = mix(u_color_low, u_color_high, normalized);

    // Black background for zero density
    float alpha = step(0.001, density);
    color = mix(vec3(0.05, 0.05, 0.1), color, alpha);

    frag_color = vec4(color, 1.0);
  }
  """

  ## ------------------------------------------------------------------
  ## Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(ctx, opts) do
    resolution = Keyword.get(opts, :resolution, @default_resolution)
    decay = Keyword.get(opts, :decay, @default_decay)
    colormap = Keyword.get(opts, :colormap, :viridis)

    # Initialize histogram as flat binary (faster than array for our use)
    histogram = :binary.copy(<<0.0::float-32-native>>, resolution * resolution)

    # Create shader program
    case create_program() do
      {:ok, program, uniforms} ->
        # Create VAO/VBO for fullscreen quad
        {vao, vbo} = create_quad()

        # Create histogram texture
        tex = create_histogram_texture(resolution)

        # Get colormap colors
        {color_low, color_high} = colormap_colors(colormap)

        {pixel_w, pixel_h} = ctx.pixel_size
        GL.viewport(0, 0, pixel_w, pixel_h)

        {:ok,
         %{
           resolution: resolution,
           decay: decay,
           histogram: histogram,
           max_value: 1.0,
           program: program,
           uniforms: uniforms,
           vao: vao,
           vbo: vbo,
           texture: tex,
           color_low: color_low,
           color_high: color_high,
           pixel_size: ctx.pixel_size
         }}

      {:error, reason} ->
        Logger.error("Constellation: shader compilation failed: #{reason}")
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
  def handle_data({:samples, binary}, state) when is_binary(binary) do
    # Accumulate samples into histogram
    {histogram, max_value} = accumulate_samples(binary, state.histogram, state.resolution, state.max_value)
    {:noreply, %{state | histogram: histogram, max_value: max_value}}
  end

  def handle_data(:clear, state) do
    resolution = state.resolution
    histogram = :binary.copy(<<0.0::float-32-native>>, resolution * resolution)
    {:noreply, %{state | histogram: histogram, max_value: 1.0}}
  end

  def handle_data(_msg, state), do: {:noreply, state}

  @impl true
  def render(state) do
    # Apply decay to histogram
    histogram = apply_decay(state.histogram, state.decay)
    max_value = state.max_value * state.decay

    # Clear
    GL.clear_color(0.05, 0.05, 0.1, 1.0)
    GL.clear(:color)

    # Upload histogram to texture
    GL.bind_texture(:texture_2d, state.texture)
    GL.tex_sub_image_2d(0, 0, state.resolution, state.resolution, :red, :float, histogram)

    # Draw
    GL.use_program(state.program)

    GL.active_texture(0)
    GL.bind_texture(:texture_2d, state.texture)
    GL.uniform_1i(state.uniforms.histogram, 0)
    GL.uniform_1f(state.uniforms.max_value, max_value)

    {lr, lg, lb} = state.color_low
    {hr, hg, hb} = state.color_high
    GL.uniform_3f(state.uniforms.color_low, lr, lg, lb)
    GL.uniform_3f(state.uniforms.color_high, hr, hg, hb)

    GL.bind_vertex_array(state.vao)
    GL.draw_arrays(:triangle_strip, 0, 4)

    {:noreply, %{state | histogram: histogram, max_value: max(max_value, 0.1)}}
  end

  @impl true
  def terminate(_reason, state) do
    GL.delete_program(state.program)
    GL.delete_vertex_array(state.vao)
    GL.delete_buffer(state.vbo)
    GL.delete_texture(state.texture)
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
        histogram: GL.get_uniform_location(program, "u_histogram"),
        max_value: GL.get_uniform_location(program, "u_max_value"),
        color_low: GL.get_uniform_location(program, "u_color_low"),
        color_high: GL.get_uniform_location(program, "u_color_high")
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
    # Triangle strip: bottom-left, bottom-right, top-left, top-right
    vertices =
      <<
        # position    texcoord
        -1.0::float-32-native, -1.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
        1.0::float-32-native, -1.0::float-32-native, 1.0::float-32-native, 0.0::float-32-native,
        -1.0::float-32-native, 1.0::float-32-native, 0.0::float-32-native, 1.0::float-32-native,
        1.0::float-32-native, 1.0::float-32-native, 1.0::float-32-native, 1.0::float-32-native
      >>

    GL.buffer_data(:array, vertices, :static)

    # Position attribute (location 0)
    GL.vertex_attrib_pointer(0, 2, :float, false, 16, 0)
    GL.enable_vertex_attrib_array(0)

    # Texcoord attribute (location 1)
    GL.vertex_attrib_pointer(1, 2, :float, false, 16, 8)
    GL.enable_vertex_attrib_array(1)

    GL.bind_vertex_array(0)

    {vao, vbo}
  end

  ## ------------------------------------------------------------------
  ## Private - Texture Setup
  ## ------------------------------------------------------------------

  defp create_histogram_texture(resolution) do
    tex = GL.create_texture()
    GL.bind_texture(:texture_2d, tex)

    # R32F texture for float histogram values
    empty = :binary.copy(<<0.0::float-32-native>>, resolution * resolution)
    GL.tex_image_2d(resolution, resolution, :r32f, :red, :float, empty)

    GL.tex_parameter(:min_filter, :linear)
    GL.tex_parameter(:mag_filter, :linear)
    GL.tex_parameter(:wrap_s, :clamp_to_edge)
    GL.tex_parameter(:wrap_t, :clamp_to_edge)

    tex
  end

  ## ------------------------------------------------------------------
  ## Private - Sample Processing
  ## ------------------------------------------------------------------

  defp accumulate_samples(binary, histogram, resolution, max_value) do
    # Parse I/Q pairs and accumulate into histogram
    samples = parse_iq_samples(binary)

    Enum.reduce(samples, {histogram, max_value}, fn {i, q}, {hist, max_v} ->
      # Map [-1, 1] to [0, resolution-1]
      x = trunc((i + 1.0) * 0.5 * (resolution - 1))
      y = trunc((q + 1.0) * 0.5 * (resolution - 1))

      # Bounds check
      if x >= 0 and x < resolution and y >= 0 and y < resolution do
        # Calculate byte offset (4 bytes per float, row-major)
        offset = (y * resolution + x) * 4

        # Extract current value, increment, put back
        <<pre::binary-size(offset), val::float-32-native, post::binary>> = hist
        new_val = val + 1.0
        new_hist = <<pre::binary, new_val::float-32-native, post::binary>>

        {new_hist, max(max_v, new_val)}
      else
        {hist, max_v}
      end
    end)
  end

  defp parse_iq_samples(binary), do: parse_iq_samples(binary, [])

  defp parse_iq_samples(<<i::float-32-little, q::float-32-little, rest::binary>>, acc) do
    parse_iq_samples(rest, [{i, q} | acc])
  end

  defp parse_iq_samples(_, acc), do: acc

  defp apply_decay(histogram, decay) do
    # Multiply all values by decay factor
    for <<val::float-32-native <- histogram>>, into: <<>> do
      <<(val * decay)::float-32-native>>
    end
  end

  ## ------------------------------------------------------------------
  ## Private - Colormaps
  ## ------------------------------------------------------------------

  defp colormap_colors(:viridis), do: {{0.267, 0.004, 0.329}, {0.993, 0.906, 0.144}}
  defp colormap_colors(:plasma), do: {{0.050, 0.030, 0.528}, {0.940, 0.975, 0.131}}
  defp colormap_colors(:hot), do: {{0.1, 0.0, 0.0}, {1.0, 1.0, 0.0}}
  defp colormap_colors(:green), do: {{0.0, 0.1, 0.0}, {0.0, 1.0, 0.3}}
  defp colormap_colors(_), do: colormap_colors(:viridis)
end
