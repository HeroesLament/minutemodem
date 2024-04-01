defmodule MinuteModemClient.Scenes.UI do
  @moduledoc """
  Root UI scene for the DTE client.

  Manages the structural composition of the UI:
  window and notebook with DTE page.
  """

  use WxMVU.Scene

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    %{
      active_window: :main,
      pages: [
        {:dte, nil}
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

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(%{active_window: window_id, pages: pages}) do
    [
      {:ensure_window, window_id, title: "MinuteModem DTE Client", size: {700, 550}},
      {:ensure_panel, :root, window_id, []},
      {:ensure_widget, :main_tabs, :notebook, :root, []}
    ] ++
      page_intents(pages) ++
      [{:refresh, window_id}]
  end

  defp page_intents(pages) do
    Enum.flat_map(pages, fn {page_id, _page_model} ->
      [
        {:ensure_panel, {:page, page_id}, :main_tabs, label: page_title(page_id)}
      ]
    end)
  end

  defp page_title(:dte), do: "DTE"
  defp page_title(other), do: to_string(other)
end
