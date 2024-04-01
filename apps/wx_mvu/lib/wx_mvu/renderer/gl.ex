defmodule WxMVU.Renderer.GL do
  @moduledoc false
  # Internal GL facade. The ONLY place :gl is called in wx_mvu.
  #
  # Canvas authors never see this module.
  # GLCanvas.Server uses this to implement the higher-level drawing API.

  alias WxEx.Constants.OpenGL

  # ============================================================================
  # Context / State
  # ============================================================================

  def viewport(x, y, w, h) do
    :gl.viewport(x, y, w, h)
  end

  def scissor(x, y, w, h) do
    :gl.scissor(x, y, w, h)
  end

  def clear_color(r, g, b, a) do
    :gl.clearColor(r, g, b, a)
  end

  def clear(:color), do: :gl.clear(OpenGL.gl_COLOR_BUFFER_BIT())
  def clear(:depth), do: :gl.clear(OpenGL.gl_DEPTH_BUFFER_BIT())
  def clear(:stencil), do: :gl.clear(OpenGL.gl_STENCIL_BUFFER_BIT())

  def clear(:all) do
    mask = Bitwise.bor(
      OpenGL.gl_COLOR_BUFFER_BIT(),
      Bitwise.bor(
        OpenGL.gl_DEPTH_BUFFER_BIT(),
        OpenGL.gl_STENCIL_BUFFER_BIT()
      )
    )
    :gl.clear(mask)
  end

  def enable(:blend), do: :gl.enable(OpenGL.gl_BLEND())
  def enable(:depth_test), do: :gl.enable(OpenGL.gl_DEPTH_TEST())
  def enable(:scissor_test), do: :gl.enable(OpenGL.gl_SCISSOR_TEST())

  def disable(:blend), do: :gl.disable(OpenGL.gl_BLEND())
  def disable(:depth_test), do: :gl.disable(OpenGL.gl_DEPTH_TEST())
  def disable(:scissor_test), do: :gl.disable(OpenGL.gl_SCISSOR_TEST())

  def blend_func(:alpha) do
    :gl.blendFunc(OpenGL.gl_SRC_ALPHA(), OpenGL.gl_ONE_MINUS_SRC_ALPHA())
  end

  def blend_func(:additive) do
    :gl.blendFunc(OpenGL.gl_SRC_ALPHA(), OpenGL.gl_ONE())
  end

  def blend_func(:premultiplied) do
    :gl.blendFunc(OpenGL.gl_ONE(), OpenGL.gl_ONE_MINUS_SRC_ALPHA())
  end

  # ============================================================================
  # Shaders
  # ============================================================================

  def create_shader(:vertex, source) do
    compile_shader(OpenGL.gl_VERTEX_SHADER(), source)
  end

  def create_shader(:fragment, source) do
    compile_shader(OpenGL.gl_FRAGMENT_SHADER(), source)
  end

  defp compile_shader(type, source) do
    shader = :gl.createShader(type)
    :gl.shaderSource(shader, [String.to_charlist(source)])
    :gl.compileShader(shader)

    case get_shader_iv(shader, OpenGL.gl_COMPILE_STATUS()) do
      1 ->
        {:ok, shader}

      0 ->
        log = get_shader_info_log(shader)
        :gl.deleteShader(shader)
        {:error, log}
    end
  end

  defp get_shader_iv(shader, pname) do
    :gl.getShaderiv(shader, pname) |> hd()
  end

  defp get_shader_info_log(shader) do
    max_len = get_shader_iv(shader, OpenGL.gl_INFO_LOG_LENGTH())
    :gl.getShaderInfoLog(shader, max_len) |> to_string()
  end

  def delete_shader(shader) do
    :gl.deleteShader(shader)
  end

  def create_program(vertex_shader, fragment_shader) do
    program = :gl.createProgram()
    :gl.attachShader(program, vertex_shader)
    :gl.attachShader(program, fragment_shader)
    :gl.linkProgram(program)

    case get_program_iv(program, OpenGL.gl_LINK_STATUS()) do
      1 ->
        {:ok, program}

      0 ->
        log = get_program_info_log(program)
        :gl.deleteProgram(program)
        {:error, log}
    end
  end

  defp get_program_iv(program, pname) do
    :gl.getProgramiv(program, pname) |> hd()
  end

  defp get_program_info_log(program) do
    max_len = get_program_iv(program, OpenGL.gl_INFO_LOG_LENGTH())
    :gl.getProgramInfoLog(program, max_len) |> to_string()
  end

  def delete_program(program) do
    :gl.deleteProgram(program)
  end

  def use_program(program) do
    :gl.useProgram(program)
  end

  def get_uniform_location(program, name) do
    :gl.getUniformLocation(program, String.to_charlist(name))
  end

  def get_attrib_location(program, name) do
    :gl.getAttribLocation(program, String.to_charlist(name))
  end

  # ============================================================================
  # Uniforms
  # ============================================================================

  def uniform_1i(location, v), do: :gl.uniform1i(location, v)
  def uniform_1f(location, v), do: :gl.uniform1f(location, v)
  def uniform_2f(location, x, y), do: :gl.uniform2f(location, x, y)
  def uniform_3f(location, x, y, z), do: :gl.uniform3f(location, x, y, z)
  def uniform_4f(location, x, y, z, w), do: :gl.uniform4f(location, x, y, z, w)

  def uniform_matrix_4fv(location, transpose, matrix) when is_list(matrix) do
    :gl.uniformMatrix4fv(location, transpose, matrix)
  end

  # ============================================================================
  # Buffers
  # ============================================================================

  def create_buffer do
    [buf] = :gl.genBuffers(1)
    buf
  end

  def create_buffers(n) do
    :gl.genBuffers(n)
  end

  def delete_buffer(buf) do
    :gl.deleteBuffers(1, [buf])
  end

  def delete_buffers(bufs) when is_list(bufs) do
    :gl.deleteBuffers(length(bufs), bufs)
  end

  def bind_buffer(:array, buf), do: :gl.bindBuffer(OpenGL.gl_ARRAY_BUFFER(), buf)
  def bind_buffer(:element, buf), do: :gl.bindBuffer(OpenGL.gl_ELEMENT_ARRAY_BUFFER(), buf)

  def buffer_data(:array, data, usage) do
    :gl.bufferData(OpenGL.gl_ARRAY_BUFFER(), byte_size(data), data, usage_hint(usage))
  end

  def buffer_data(:element, data, usage) do
    :gl.bufferData(OpenGL.gl_ELEMENT_ARRAY_BUFFER(), byte_size(data), data, usage_hint(usage))
  end

  def buffer_sub_data(:array, offset, data) do
    :gl.bufferSubData(OpenGL.gl_ARRAY_BUFFER(), offset, byte_size(data), data)
  end

  def buffer_sub_data(:element, offset, data) do
    :gl.bufferSubData(OpenGL.gl_ELEMENT_ARRAY_BUFFER(), offset, byte_size(data), data)
  end

  defp usage_hint(:static), do: OpenGL.gl_STATIC_DRAW()
  defp usage_hint(:dynamic), do: OpenGL.gl_DYNAMIC_DRAW()
  defp usage_hint(:stream), do: OpenGL.gl_STREAM_DRAW()

  # ============================================================================
  # Vertex Arrays
  # ============================================================================

  def create_vertex_array do
    [vao] = :gl.genVertexArrays(1)
    vao
  end

  def delete_vertex_array(vao) do
    :gl.deleteVertexArrays(1, [vao])
  end

  def bind_vertex_array(vao) do
    :gl.bindVertexArray(vao)
  end

  def vertex_attrib_pointer(index, size, type, normalized, stride, offset) do
    :gl.vertexAttribPointer(
      index,
      size,
      attrib_type(type),
      bool_to_gl(normalized),
      stride,
      offset
    )
  end

  def enable_vertex_attrib_array(index) do
    :gl.enableVertexAttribArray(index)
  end

  def disable_vertex_attrib_array(index) do
    :gl.disableVertexAttribArray(index)
  end

  defp attrib_type(:float), do: OpenGL.gl_FLOAT()
  defp attrib_type(:int), do: OpenGL.gl_INT()
  defp attrib_type(:unsigned_int), do: OpenGL.gl_UNSIGNED_INT()
  defp attrib_type(:byte), do: OpenGL.gl_BYTE()
  defp attrib_type(:unsigned_byte), do: OpenGL.gl_UNSIGNED_BYTE()
  defp attrib_type(:short), do: OpenGL.gl_SHORT()
  defp attrib_type(:unsigned_short), do: OpenGL.gl_UNSIGNED_SHORT()

  defp bool_to_gl(true), do: OpenGL.gl_TRUE()
  defp bool_to_gl(false), do: OpenGL.gl_FALSE()

  # ============================================================================
  # Textures
  # ============================================================================

  def create_texture do
    [tex] = :gl.genTextures(1)
    tex
  end

  def delete_texture(tex) do
    :gl.deleteTextures(1, [tex])
  end

  def bind_texture(:texture_2d, tex) do
    :gl.bindTexture(OpenGL.gl_TEXTURE_2D(), tex)
  end

  def active_texture(unit) when is_integer(unit) do
    :gl.activeTexture(OpenGL.gl_TEXTURE0() + unit)
  end

  def tex_image_2d(width, height, internal_format, format, type, data) do
    :gl.texImage2D(
      OpenGL.gl_TEXTURE_2D(),
      0,
      internal_format(internal_format),
      width,
      height,
      0,
      pixel_format(format),
      pixel_type(type),
      data
    )
  end

  def tex_sub_image_2d(x, y, width, height, format, type, data) do
    :gl.texSubImage2D(
      OpenGL.gl_TEXTURE_2D(),
      0,
      x,
      y,
      width,
      height,
      pixel_format(format),
      pixel_type(type),
      data
    )
  end

  def tex_parameter(:min_filter, value) do
    :gl.texParameteri(OpenGL.gl_TEXTURE_2D(), OpenGL.gl_TEXTURE_MIN_FILTER(), filter(value))
  end

  def tex_parameter(:mag_filter, value) do
    :gl.texParameteri(OpenGL.gl_TEXTURE_2D(), OpenGL.gl_TEXTURE_MAG_FILTER(), filter(value))
  end

  def tex_parameter(:wrap_s, value) do
    :gl.texParameteri(OpenGL.gl_TEXTURE_2D(), OpenGL.gl_TEXTURE_WRAP_S(), wrap(value))
  end

  def tex_parameter(:wrap_t, value) do
    :gl.texParameteri(OpenGL.gl_TEXTURE_2D(), OpenGL.gl_TEXTURE_WRAP_T(), wrap(value))
  end

  defp filter(:linear), do: OpenGL.gl_LINEAR()
  defp filter(:nearest), do: OpenGL.gl_NEAREST()
  defp filter(:linear_mipmap_linear), do: OpenGL.gl_LINEAR_MIPMAP_LINEAR()
  defp filter(:linear_mipmap_nearest), do: OpenGL.gl_LINEAR_MIPMAP_NEAREST()
  defp filter(:nearest_mipmap_linear), do: OpenGL.gl_NEAREST_MIPMAP_LINEAR()
  defp filter(:nearest_mipmap_nearest), do: OpenGL.gl_NEAREST_MIPMAP_NEAREST()

  defp wrap(:clamp_to_edge), do: OpenGL.gl_CLAMP_TO_EDGE()
  defp wrap(:repeat), do: OpenGL.gl_REPEAT()
  defp wrap(:mirrored_repeat), do: OpenGL.gl_MIRRORED_REPEAT()

  defp internal_format(:rgb), do: OpenGL.gl_RGB()
  defp internal_format(:rgba), do: OpenGL.gl_RGBA()
  defp internal_format(:red), do: OpenGL.gl_RED()
  defp internal_format(:rg), do: OpenGL.gl_RG()
  defp internal_format(:rgb8), do: OpenGL.gl_RGB8()
  defp internal_format(:rgba8), do: OpenGL.gl_RGBA8()
  defp internal_format(:r8), do: OpenGL.gl_R8()
  defp internal_format(:r16f), do: OpenGL.gl_R16F()
  defp internal_format(:r32f), do: OpenGL.gl_R32F()
  defp internal_format(:rgb32f), do: OpenGL.gl_RGB32F()
  defp internal_format(:rgba32f), do: OpenGL.gl_RGBA32F()

  defp pixel_format(:rgb), do: OpenGL.gl_RGB()
  defp pixel_format(:rgba), do: OpenGL.gl_RGBA()
  defp pixel_format(:red), do: OpenGL.gl_RED()
  defp pixel_format(:rg), do: OpenGL.gl_RG()
  defp pixel_format(:bgr), do: OpenGL.gl_BGR()
  defp pixel_format(:bgra), do: OpenGL.gl_BGRA()

  defp pixel_type(:unsigned_byte), do: OpenGL.gl_UNSIGNED_BYTE()
  defp pixel_type(:float), do: OpenGL.gl_FLOAT()
  defp pixel_type(:unsigned_short), do: OpenGL.gl_UNSIGNED_SHORT()
  defp pixel_type(:unsigned_int), do: OpenGL.gl_UNSIGNED_INT()

  # ============================================================================
  # Drawing
  # ============================================================================

  def draw_arrays(:points, first, count) do
    :gl.drawArrays(OpenGL.gl_POINTS(), first, count)
  end

  def draw_arrays(:lines, first, count) do
    :gl.drawArrays(OpenGL.gl_LINES(), first, count)
  end

  def draw_arrays(:line_strip, first, count) do
    :gl.drawArrays(OpenGL.gl_LINE_STRIP(), first, count)
  end

  def draw_arrays(:line_loop, first, count) do
    :gl.drawArrays(OpenGL.gl_LINE_LOOP(), first, count)
  end

  def draw_arrays(:triangles, first, count) do
    :gl.drawArrays(OpenGL.gl_TRIANGLES(), first, count)
  end

  def draw_arrays(:triangle_strip, first, count) do
    :gl.drawArrays(OpenGL.gl_TRIANGLE_STRIP(), first, count)
  end

  def draw_arrays(:triangle_fan, first, count) do
    :gl.drawArrays(OpenGL.gl_TRIANGLE_FAN(), first, count)
  end

  def draw_elements(:triangles, count, :unsigned_int, offset) do
    :gl.drawElements(OpenGL.gl_TRIANGLES(), count, OpenGL.gl_UNSIGNED_INT(), offset)
  end

  def draw_elements(:triangles, count, :unsigned_short, offset) do
    :gl.drawElements(OpenGL.gl_TRIANGLES(), count, OpenGL.gl_UNSIGNED_SHORT(), offset)
  end

  def draw_elements(:triangles, count, :unsigned_byte, offset) do
    :gl.drawElements(OpenGL.gl_TRIANGLES(), count, OpenGL.gl_UNSIGNED_BYTE(), offset)
  end

  # ============================================================================
  # Framebuffers (for offscreen rendering)
  # ============================================================================

  def create_framebuffer do
    [fbo] = :gl.genFramebuffers(1)
    fbo
  end

  def delete_framebuffer(fbo) do
    :gl.deleteFramebuffers(1, [fbo])
  end

  def bind_framebuffer(:draw, fbo) do
    :gl.bindFramebuffer(OpenGL.gl_DRAW_FRAMEBUFFER(), fbo)
  end

  def bind_framebuffer(:read, fbo) do
    :gl.bindFramebuffer(OpenGL.gl_READ_FRAMEBUFFER(), fbo)
  end

  def bind_framebuffer(:both, fbo) do
    :gl.bindFramebuffer(OpenGL.gl_FRAMEBUFFER(), fbo)
  end

  def bind_default_framebuffer do
    :gl.bindFramebuffer(OpenGL.gl_FRAMEBUFFER(), 0)
  end

  def framebuffer_texture_2d(:color, attachment_index, texture) do
    :gl.framebufferTexture2D(
      OpenGL.gl_FRAMEBUFFER(),
      OpenGL.gl_COLOR_ATTACHMENT0() + attachment_index,
      OpenGL.gl_TEXTURE_2D(),
      texture,
      0
    )
  end

  def framebuffer_texture_2d(:depth, texture) do
    :gl.framebufferTexture2D(
      OpenGL.gl_FRAMEBUFFER(),
      OpenGL.gl_DEPTH_ATTACHMENT(),
      OpenGL.gl_TEXTURE_2D(),
      texture,
      0
    )
  end

  def check_framebuffer_status do
    status = :gl.checkFramebufferStatus(OpenGL.gl_FRAMEBUFFER())
    complete = OpenGL.gl_FRAMEBUFFER_COMPLETE()
    incomplete_attachment = OpenGL.gl_FRAMEBUFFER_INCOMPLETE_ATTACHMENT()
    missing_attachment = OpenGL.gl_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT()
    unsupported = OpenGL.gl_FRAMEBUFFER_UNSUPPORTED()

    cond do
      status == complete -> :complete
      status == incomplete_attachment -> {:error, :incomplete_attachment}
      status == missing_attachment -> {:error, :missing_attachment}
      status == unsupported -> {:error, :unsupported}
      true -> {:error, {:unknown, status}}
    end
  end

  # ============================================================================
  # Renderbuffers
  # ============================================================================

  def create_renderbuffer do
    [rbo] = :gl.genRenderbuffers(1)
    rbo
  end

  def delete_renderbuffer(rbo) do
    :gl.deleteRenderbuffers(1, [rbo])
  end

  def bind_renderbuffer(rbo) do
    :gl.bindRenderbuffer(OpenGL.gl_RENDERBUFFER(), rbo)
  end

  def renderbuffer_storage(:depth24_stencil8, width, height) do
    :gl.renderbufferStorage(
      OpenGL.gl_RENDERBUFFER(),
      OpenGL.gl_DEPTH24_STENCIL8(),
      width,
      height
    )
  end

  def framebuffer_renderbuffer(:depth_stencil, rbo) do
    :gl.framebufferRenderbuffer(
      OpenGL.gl_FRAMEBUFFER(),
      OpenGL.gl_DEPTH_STENCIL_ATTACHMENT(),
      OpenGL.gl_RENDERBUFFER(),
      rbo
    )
  end

  # ============================================================================
  # Error Checking
  # ============================================================================

  def get_error do
    err = :gl.getError()
    no_error = OpenGL.gl_NO_ERROR()
    invalid_enum = OpenGL.gl_INVALID_ENUM()
    invalid_value = OpenGL.gl_INVALID_VALUE()
    invalid_operation = OpenGL.gl_INVALID_OPERATION()
    out_of_memory = OpenGL.gl_OUT_OF_MEMORY()
    invalid_framebuffer = OpenGL.gl_INVALID_FRAMEBUFFER_OPERATION()

    cond do
      err == no_error -> :ok
      err == invalid_enum -> {:error, :invalid_enum}
      err == invalid_value -> {:error, :invalid_value}
      err == invalid_operation -> {:error, :invalid_operation}
      err == out_of_memory -> {:error, :out_of_memory}
      err == invalid_framebuffer -> {:error, :invalid_framebuffer_operation}
      true -> {:error, {:unknown, err}}
    end
  end

  def assert_no_error! do
    case get_error() do
      :ok -> :ok
      {:error, reason} -> raise "GL error: #{inspect(reason)}"
    end
  end
end
