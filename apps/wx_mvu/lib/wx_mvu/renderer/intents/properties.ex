defmodule WxMVU.Renderer.Intents.Properties do
  use WxEx

  def apply({:set, widget_id, props}, state) do
    case Map.get(state.widgets, widget_id) do
      nil ->
        state

      widget ->
        Enum.each(props, fn {key, value} ->
          set_property(widget, key, value)
        end)

        state
    end
  end

  defp set_property(widget, :text, value) when is_binary(value) do
    try do
      :wxStatusBar.setStatusText(widget, value)
    catch
      _, _ -> :wxStaticText.setLabel(widget, value)
    end
  end

  defp set_property(widget, :value, value) when is_binary(value) do
    :wxTextCtrl.setValue(widget, value)
  end

  defp set_property(widget, :value, value) when is_integer(value) do
    try do
      :wxGauge.setValue(widget, value)
    catch
      _, _ ->
        try do
          :wxSpinCtrl.setValue(widget, value)
        catch
          _, _ -> :wxSlider.setValue(widget, value)
        end
    end
  end

  defp set_property(widget, :value, value) when is_boolean(value) do
    try do
      :wxToggleButton.setValue(widget, value)
    catch
      _, _ -> :wxCheckBox.setValue(widget, value)
    end
  end

  defp set_property(widget, :selected, nil) do
    # Clear selection
    try do
      :wxChoice.setSelection(widget, -1)
    catch
      _, _ -> :ok
    end
  end

  defp set_property(widget, :selected, value) when is_integer(value) do
    try do
      :wxListBox.setSelection(widget, value)
    catch
      _, _ ->
        try do
          :wxChoice.setSelection(widget, value)
        catch
          _, _ -> :wxRadioBox.setSelection(widget, value)
        end
    end
  end

  defp set_property(widget, :items, items) when is_list(items) do
    try do
      :wxListBox.clear(widget)
      Enum.each(items, &:wxListBox.append(widget, to_string(&1)))
    catch
      _, _ ->
        :wxChoice.clear(widget)
        Enum.each(items, &:wxChoice.append(widget, to_string(&1)))
    end
  end

  defp set_property(widget, :range, value) when is_integer(value) do
    :wxGauge.setRange(widget, value)
  end

  defp set_property(_widget, _key, _value), do: :ok
end
