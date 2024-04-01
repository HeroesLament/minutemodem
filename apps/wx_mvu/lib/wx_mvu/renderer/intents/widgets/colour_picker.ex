defmodule WxMVU.Renderer.Intents.Widgets.ColourPicker do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :colour_picker, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for colour_picker #{inspect(widget_id)}")
        state
      else
        style = colour_picker_style(opts)

        widget =
          :wxColourPickerCtrl.new(
            parent,
            wxID_ANY(),
            style: style
          )

        # Set initial colour if provided
        if colour = Keyword.get(opts, :colour) do
          :wxColourPickerCtrl.setColour(widget, colour)
        end

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_colourpicker_changed)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp colour_picker_style(opts) do
    base = wxCLRP_DEFAULT_STYLE()

    base = if Keyword.get(opts, :show_label, false), do: Bitwise.bor(base, wxCLRP_SHOW_LABEL()), else: base
    base = if Keyword.get(opts, :show_alpha, false), do: Bitwise.bor(base, wxCLRP_SHOW_ALPHA()), else: base
    base = if Keyword.get(opts, :use_textctrl, false), do: Bitwise.bor(base, wxCLRP_USE_TEXTCTRL()), else: base

    base
  end
end
