defmodule WxMVU.Renderer.Intents.Widgets.SpinCtrl do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :spin_ctrl, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for spin_ctrl #{inspect(widget_id)}")
        state
      else
        min = Keyword.get(opts, :min, 0)
        max = Keyword.get(opts, :max, 100)
        initial = Keyword.get(opts, :value, min)

        widget =
          :wxSpinCtrl.new(
            parent,
            id: wxID_ANY(),
            min: min,
            max: max,
            initial: initial
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: 0,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_spinctrl_updated)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  # For now, use text ctrl for doubles
  # wxSpinCtrlDouble may not be available in all wx versions
  def apply({:ensure_widget, widget_id, :spin_ctrl_double, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for spin_ctrl_double #{inspect(widget_id)}")
        state
      else
        _min = Keyword.get(opts, :min, 0.0)
        _max = Keyword.get(opts, :max, 100.0)
        initial = Keyword.get(opts, :value, 0.0)
        _increment = Keyword.get(opts, :increment, 0.1)

        widget =
          :wxTextCtrl.new(
            parent,
            wxID_ANY(),
            value: :erlang.float_to_binary(initial, decimals: 3)
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

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end
end
