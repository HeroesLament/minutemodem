defmodule WxMVU.Renderer.Intents.Widgets.Button do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :button, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for button #{inspect(widget_id)}")
        state
      else
        label = Keyword.get(opts, :label, "")
        align = Keyword.get(opts, :align, :center)

        widget =
          :wxButton.new(
            parent,
            wxID_ANY(),
            label: label
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        flag = Bitwise.bor(wxALL(), align_flag(align))

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: flag,
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_button_clicked)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp align_flag(:center), do: wxALIGN_CENTER_HORIZONTAL()
  defp align_flag(:left), do: wxALIGN_LEFT()
  defp align_flag(:right), do: wxALIGN_RIGHT()
  defp align_flag(:expand), do: wxEXPAND()
  defp align_flag(_), do: wxALIGN_CENTER_HORIZONTAL()
end
