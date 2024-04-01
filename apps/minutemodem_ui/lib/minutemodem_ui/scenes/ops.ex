defmodule MinuteModemUI.Scenes.Ops do
  @moduledoc """
  Ops scene - main operational interface.

  Select an active rig from dropdown, choose waveform, then SCAN or CALL.
  """

  use WxMVU.Scene

  alias MinuteModemUI.CoreClient

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    running = CoreClient.list_running_rigs()

    %{
      running_rigs: running,
      active_rig_id: List.first(running),
      waveform: :fast,
      tuner_time_ms: 40,
      show_call_dialog: false,
      ale_state: :idle
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :ops_rig_select, :change, index}, model) do
    rig_id = Enum.at(model.running_rigs, index)
    %{model | active_rig_id: rig_id}
  end

  def handle_event({:ui_event, :ops_refresh, :click}, model) do
    running = CoreClient.list_running_rigs()

    %{model |
      running_rigs: running,
      active_rig_id: List.first(running)
    }
  end

  def handle_event({:ui_event, :ops_waveform, :change, index}, model) do
    waveform = case index do
      0 -> :fast
      1 -> :deep
      _ -> :fast
    end
    %{model | waveform: waveform}
  end

  def handle_event({:ui_event, :ops_tuner_time, :change, value}, model) do
    %{model | tuner_time_ms: value}
  end

  def handle_event({:ui_event, :ops_scan, :click}, model) do
    if model.active_rig_id do
      IO.puts("SCAN on rig #{model.active_rig_id} with #{model.waveform} waveform")

      case CoreClient.ale_scan(model.active_rig_id, waveform: model.waveform) do
        :ok ->
          %{model | ale_state: :scanning}
        {:error, reason} ->
          IO.puts("SCAN failed: #{inspect(reason)}")
          model
        {:badrpc, _} ->
          IO.puts("SCAN failed: core not reachable")
          model
      end
    else
      model
    end
  end

  def handle_event({:ui_event, :ops_stop, :click}, model) do
    if model.active_rig_id do
      IO.puts("STOP on rig #{model.active_rig_id}")
      CoreClient.ale_stop(model.active_rig_id)
      %{model | ale_state: :idle}
    else
      model
    end
  end

  def handle_event({:ui_event, :ops_call, :click}, model) do
    if model.active_rig_id do
      %{model | show_call_dialog: true}
    else
      model
    end
  end

  def handle_event({:dialog_result, :call_dialog, {:ok, %{dest_addr: addr}}}, model) do
    if model.active_rig_id do
      dest = parse_hex(addr)
      IO.puts("CALL 0x#{Integer.to_string(dest || 0, 16)} on rig #{model.active_rig_id} with #{model.waveform} waveform")

      case CoreClient.ale_call(model.active_rig_id, dest,
             waveform: model.waveform,
             tuner_time_ms: model.tuner_time_ms) do
        :ok ->
          %{model | show_call_dialog: false, ale_state: :calling}
        {:error, reason} ->
          IO.puts("CALL failed: #{inspect(reason)}")
          %{model | show_call_dialog: false}
        {:badrpc, _} ->
          IO.puts("CALL failed: core not reachable")
          %{model | show_call_dialog: false}
      end
    else
      %{model | show_call_dialog: false}
    end
  end

  def handle_event({:dialog_result, :call_dialog, :cancel}, model) do
    %{model | show_call_dialog: false}
  end

  def handle_event({:ale_state_change, rig_id, state, _info}, model) do
    if rig_id == model.active_rig_id do
      %{model | ale_state: state}
    else
      model
    end
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    [
      {:ensure_panel, :ops_root, {:page, :ops}, []}
    ] ++
      rig_selector(model) ++
      waveform_controls(model) ++
      action_buttons(model) ++
      rig_status(model) ++
      call_dialog(model) ++
      [
        {:layout, :ops_root,
         {:vbox, [padding: 10],
          [
            {:hbox, [], [:ops_rig_label, :ops_rig_select, {:spacer, 10}, :ops_refresh]},
            {:spacer, 15},
            {:hbox, [], [:ops_waveform_label, :ops_waveform, {:spacer, 20},
                         :ops_tuner_label, :ops_tuner_time]},
            {:spacer, 20},
            {:hbox, [align: :center], [:ops_scan, {:spacer, 10}, :ops_stop, {:spacer, 10}, :ops_call]},
            {:spacer, 20},
            :ops_status,
            {:spacer, 10},
            :ops_timing_info
          ]}}
      ]
  end

  defp rig_selector(model) do
    rig_names = Enum.map(model.running_rigs, &rig_display_name/1)
    selected = Enum.find_index(model.running_rigs, &(&1 == model.active_rig_id)) || 0

    [
      {:ensure_widget, :ops_rig_label, :static_text, :ops_root, label: "Active Rig:"},
      {:ensure_widget, :ops_rig_select, :choice, :ops_root, choices: rig_names},
      {:set, :ops_rig_select, items: rig_names},
      {:set, :ops_rig_select, selected: selected},
      {:ensure_widget, :ops_refresh, :button, :ops_root, label: "↻"}
    ]
  end

  defp waveform_controls(model) do
    waveform_choices = ["Fast WALE (120ms)", "Deep WALE (240ms)"]
    waveform_index = case model.waveform do
      :fast -> 0
      :deep -> 1
      _ -> 0
    end

    [
      {:ensure_widget, :ops_waveform_label, :static_text, :ops_root, label: "Waveform:"},
      {:ensure_widget, :ops_waveform, :choice, :ops_root, choices: waveform_choices},
      {:set, :ops_waveform, selected: waveform_index},
      {:ensure_widget, :ops_tuner_label, :static_text, :ops_root, label: "Tuner (ms):"},
      {:ensure_widget, :ops_tuner_time, :spin_ctrl, :ops_root,
       min: 0, max: 500, value: model.tuner_time_ms}
    ]
  end

  defp action_buttons(model) do
    {scan_label, scan_enabled} = case model.ale_state do
      :scanning -> {"SCANNING", false}
      :idle -> {"SCAN", true}
      _ -> {"SCAN", false}
    end

    call_enabled = model.ale_state == :idle
    stop_enabled = model.ale_state != :idle

    [
      {:ensure_widget, :ops_scan, :button, :ops_root, label: scan_label, size: {100, 60}},
      {:set, :ops_scan, enabled: scan_enabled},
      {:ensure_widget, :ops_stop, :button, :ops_root, label: "STOP", size: {80, 60}},
      {:set, :ops_stop, enabled: stop_enabled},
      {:ensure_widget, :ops_call, :button, :ops_root, label: "CALL", size: {100, 60}},
      {:set, :ops_call, enabled: call_enabled}
    ]
  end

  defp rig_status(%{active_rig_id: nil}) do
    [
      {:ensure_widget, :ops_status, :static_text, :ops_root,
       label: "No rig selected. Start a rig in the Rigs tab."},
      {:ensure_widget, :ops_timing_info, :static_text, :ops_root, label: ""}
    ]
  end

  defp rig_status(%{active_rig_id: rig_id} = model) do
    status_text =
      case CoreClient.ale_state(rig_id) do
        {:idle, _} -> "IDLE"
        {:scanning, _} -> "SCANNING..."
        {:calling, info} -> "CALLING #{format_addr(info[:remote_addr])}"
        {:linked, info} -> "LINKED to #{format_addr(info[:remote_addr])}"
        {:lbt, _} -> "LBT (Listen Before Transmit)..."
        {:lbr, _} -> "LBR (Listen Before Respond)..."
        {:responding, info} -> "RESPONDING to #{format_addr(info[:remote_addr])}"
        other -> inspect(other)
      end

    timing_text = format_timing_info(model.waveform)

    [
      {:ensure_widget, :ops_status, :static_text, :ops_root, label: "ALE: #{status_text}"},
      {:set, :ops_status, label: "ALE: #{status_text}"},
      {:ensure_widget, :ops_timing_info, :static_text, :ops_root, label: timing_text},
      {:set, :ops_timing_info, label: timing_text}
    ]
  end

  defp format_timing_info(:fast), do: "Fast WALE: 120ms preamble, ~2400 bps"
  defp format_timing_info(:deep), do: "Deep WALE: 240ms preamble, ~150 bps"
  defp format_timing_info(_), do: ""

  defp call_dialog(%{show_call_dialog: true}) do
    [
      {:show_dialog, :call_dialog, :form, :main,
       title: "ALE Call",
       fields: [
         {:dest_addr, :text, label: "Destination Address (hex)", value: ""}
       ]}
    ]
  end

  defp call_dialog(_), do: []

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp rig_display_name(rig_id) do
    String.slice(rig_id, 0, 8)
  end

  defp parse_hex(nil), do: nil
  defp parse_hex(""), do: nil
  defp parse_hex(str) when is_binary(str) do
    str = String.trim(str)
    str = String.replace_prefix(str, "0x", "")
    str = String.replace_prefix(str, "0X", "")

    case Integer.parse(str, 16) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp format_addr(nil), do: "?"
  defp format_addr(addr) when is_integer(addr), do: "0x#{Integer.to_string(addr, 16)}"
  defp format_addr(_), do: "?"
end
