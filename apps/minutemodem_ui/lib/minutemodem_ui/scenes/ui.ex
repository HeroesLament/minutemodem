defmodule MinuteModemUI.Scenes.UI do
  @moduledoc """
  Root UI scene.

  Manages the structural composition of the UI:
  windows, notebooks, and pages (tabs).
  """

  use WxMVU.Scene

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    %{
      active_window: :main,
      active_tab: 0,
      pages: [
        {:ops, nil},
        {:rigs, nil},
        {:nets, nil},
        {:callsigns, nil},
        {:config, nil}
      ]
    }
  end
  ## ------------------------------------------------------------------
  ## Handle Event
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :main, :close_window, _}, model) do
    System.stop(0)
    model
  end

  def handle_event({:ui_event, :main_tabs, :page_changed, tab_index}, model) do
    %{model | active_tab: tab_index}
  end

  def handle_event({:put_page, page_id, page_model}, model) do
    pages = List.keystore(model.pages, page_id, 0, {page_id, page_model})
    %{model | pages: pages}
  end

  def handle_event({:remove_page, page_id}, model) do
    pages = List.keydelete(model.pages, page_id, 0)
    %{model | pages: pages}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(%{active_window: window_id, pages: pages}) do
    window_intents(window_id) ++
      root_intents(window_id) ++
      notebook_intents() ++
      page_intents(pages) ++
      [{:refresh, window_id}]
  end

  defp window_intents(window_id) do
    [
      {:ensure_window, window_id, title: "MinuteModem"}
    ]
  end

  defp root_intents(window_id) do
    [
      {:ensure_panel, :root, window_id, []}
    ]
  end

  defp notebook_intents do
    [
      {:ensure_widget, :main_tabs, :notebook, :root, []}
    ]
  end

  defp page_intents(pages) do
    Enum.flat_map(pages, fn {page_id, _page_model} ->
      [
        {:ensure_panel, {:page, page_id}, :main_tabs,
         label: page_title(page_id)}
      ]
    end)
  end

  defp page_title(:ops), do: "Ops"
  defp page_title(:rigs), do: "Rigs"
  defp page_title(:nets), do: "Nets"
  defp page_title(:callsigns), do: "Callsigns"
  defp page_title(:config), do: "Config"
  defp page_title(other), do: to_string(other)
end
