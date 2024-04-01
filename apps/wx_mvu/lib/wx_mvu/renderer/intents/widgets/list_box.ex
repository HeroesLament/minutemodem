defmodule WxMVU.Renderer.Intents.Widgets.ListBox do
  use WxEx
  require Logger

  def apply({:ensure_widget, widget_id, :list_box, parent_id, opts}, state) do
    if Map.has_key?(state.widgets, widget_id) do
      state
    else
      parent = Map.get(state.panels, parent_id)

      if is_nil(parent) do
        Logger.debug("Renderer: parent not ready for list_box #{inspect(widget_id)}")
        state
      else
        items = Keyword.get(opts, :choices, Keyword.get(opts, :items, []))
        style = list_style(opts)

        widget =
          :wxListBox.new(
            parent,
            wxID_ANY(),
            choices: Enum.map(items, &to_string/1),
            style: style
          )

        parent_sizer = Map.fetch!(state.sizers, parent_id)

        proportion = Keyword.get(opts, :proportion, 1)

        :wxSizer.add(
          parent_sizer,
          widget,
          proportion: proportion,
          flag: Bitwise.bor(wxALL(), wxEXPAND()),
          border: 6
        )

        :wxEvtHandler.connect(widget, :command_listbox_selected)
        :wxEvtHandler.connect(widget, :command_listbox_doubleclicked)

        :wxWindow.layout(parent)

        %{
          state
          | widgets: Map.put(state.widgets, widget_id, widget),
            widget_ids: Map.put(state.widget_ids, widget, widget_id)
        }
      end
    end
  end

  defp list_style(opts) do
    base = wxLB_SINGLE()

    base = if Keyword.get(opts, :multiple, false), do: wxLB_MULTIPLE(), else: base
    base = if Keyword.get(opts, :extended, false), do: wxLB_EXTENDED(), else: base
    base = if Keyword.get(opts, :sort, false), do: Bitwise.bor(base, wxLB_SORT()), else: base
    base = if Keyword.get(opts, :always_show_scrollbar, false), do: Bitwise.bor(base, wxLB_ALWAYS_SB()), else: base

    base
  end
end
