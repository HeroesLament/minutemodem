defmodule WxMVU.Renderer.Intents.Widgets.TextCtrl do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :text_ctrl, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for text_ctrl #{inspect(widget_id)}")
        state
      else
        value = Keyword.get(opts, :value, "")
        style = text_style(opts)

        widget =
          :wxTextCtrl.new(
            parent,
            wxID_ANY(),
            value: value,
            style: style
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_text_updated)
        :wxEvtHandler.connect(widget, :command_text_enter)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp text_style(opts) do
    base = 0

    base = if Keyword.get(opts, :multiline, false), do: Bitwise.bor(base, wxTE_MULTILINE()), else: base
    base = if Keyword.get(opts, :password, false), do: Bitwise.bor(base, wxTE_PASSWORD()), else: base
    base = if Keyword.get(opts, :readonly, false), do: Bitwise.bor(base, wxTE_READONLY()), else: base
    base = if Keyword.get(opts, :process_enter, false), do: Bitwise.bor(base, wxTE_PROCESS_ENTER()), else: base

    base
  end
end
