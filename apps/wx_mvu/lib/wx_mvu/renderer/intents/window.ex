defmodule WxMVU.Renderer.Intents.Window do
  use WxEx
  require Logger

  def apply({:ensure_window, window_id, opts}, state) do
      if Map.has_key?(state.windows, window_id) do
        state
      else
        title = Keyword.get(opts, :title, Atom.to_string(window_id))
        size = Keyword.get(opts, :size, {1024, 768})

        frame =
          :wxFrame.new(
            state.wx,
            wxID_ANY(),
            title,
            size: size
          )

        sizer = :wxBoxSizer.new(wxVERTICAL())
        :wxFrame.setSizer(frame, sizer)
        :wxFrame.show(frame)

        # Subscribe to window close event
        :wxFrame.connect(frame, :close_window)

        %{
          state
          | windows: Map.put(state.windows, window_id, frame),
            sizers: Map.put(state.sizers, window_id, sizer),
            widget_ids: Map.put(state.widget_ids, frame, window_id)
        }
    end
  end

  def apply({:update_window, window_id, opts}, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        Logger.debug("Renderer: cannot update non-existent window #{inspect(window_id)}")
        state

      frame ->
        if title = Keyword.get(opts, :title) do
          :wxFrame.setTitle(frame, title)
        end

        if size = Keyword.get(opts, :size) do
          :wxFrame.setSize(frame, size)
        end

        state
    end
  end

  def apply({:destroy_window, window_id}, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        state

      frame ->
        :wxFrame.destroy(frame)

        %{
          state
          | windows: Map.delete(state.windows, window_id),
            sizers: Map.delete(state.sizers, window_id)
        }
    end
  end

  def apply({:refresh, window_id}, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        state

      window ->
        :wxWindow.layout(window)
        :wxWindow.refresh(window)
        :wxWindow.update(window)
        state
    end
  end
end
