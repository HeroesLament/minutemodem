defmodule MinuteModemUI.Scenes.Ops do
  @moduledoc """
  Ops scene - main operational interface.

  Select an active rig from dropdown, choose waveform, then SCAN or CALL.
  Displays a live spectrogram of the rig's RX channel audio.
  """

  use WxMVU.Scene

  require Logger

  alias MinuteModemUI.CoreClient
  alias MinuteModemUI.Audio.RxMonitor
  alias MinuteModemUI.DSP

  @fft_size 512
  @fft_window :hann

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    {:ok, rx_monitor} = RxMonitor.start_link(owner: self())
    running = CoreClient.list_running_rigs()
    active = List.first(running)

    # Attach to first running rig immediately
    if active do
      RxMonitor.attach(rx_monitor, active)
      join_rig_events(active)
    end

    # Start periodic stats timer
    Process.send_after(self(), :stats_tick, 1000)

    %{
      running_rigs: running,
      active_rig_id: active,
      waveform: :fast,
      tuner_time_ms: 40,
      show_call_dialog: false,
      ale_state: :idle,
      ale_info: nil,
      rx_monitor: rx_monitor,
      rx_attached: active != nil,
      # Net selection
      nets: load_nets(),
      selected_net_index: 0,  # 0 = "Ad-hoc (default channels)"
      # Debug stats
      audio_chunks: 0,
      audio_samples: 0,
      stats_text: ""
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :ops_rig_select, :change, index}, model) do
    rig_id = Enum.at(model.running_rigs, index)

    # Re-attach RxMonitor to newly selected rig
    if rig_id && rig_id != model.active_rig_id do
      if model.active_rig_id, do: leave_rig_events(model.active_rig_id)
      RxMonitor.attach(model.rx_monitor, rig_id)
      join_rig_events(rig_id)
      WxMVU.GLCanvas.send_data(:ops_spectrogram, :clear)
    end

    %{model | active_rig_id: rig_id, ale_state: :idle, rx_attached: rig_id != nil}
  end

  def handle_event({:ui_event, :ops_refresh, :click}, model) do
    running = CoreClient.list_running_rigs()
    nets = load_nets()
    active = if Enum.member?(running, model.active_rig_id) do
      model.active_rig_id
    else
      List.first(running)
    end

    # Re-attach if active rig changed
    if active != model.active_rig_id do
      if model.active_rig_id, do: leave_rig_events(model.active_rig_id)
      if active do
        RxMonitor.attach(model.rx_monitor, active)
        join_rig_events(active)
      else
        RxMonitor.detach(model.rx_monitor)
      end
      WxMVU.GLCanvas.send_data(:ops_spectrogram, :clear)
    end

    # Clamp net selection if nets list shrank
    net_idx = min(model.selected_net_index, length(nets))

    %{model |
      running_rigs: running,
      active_rig_id: active,
      rx_attached: active != nil,
      nets: nets,
      selected_net_index: net_idx
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

  def handle_event({:ui_event, :ops_net_select, :change, index}, model) do
    %{model | selected_net_index: index}
  end

  def handle_event({:ui_event, :ops_scan, :click}, model) do
    if model.active_rig_id do
      scan_opts = [waveform: model.waveform] ++ selected_net_opts(model)

      case CoreClient.ale_scan(model.active_rig_id, scan_opts) do
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
      CoreClient.ale_stop(model.active_rig_id)
      %{model | ale_state: :idle}
    else
      model
    end
  end

  def handle_event({:ui_event, :ops_call, :click}, model) do
    if model.active_rig_id do
      # Send dialog intent directly to renderer — don't put in view()
      # because non-diffable intents re-fire on every render cycle
      WxMVU.Renderer.render(
        {:show_dialog, :call_dialog, :form, :main,
         title: "ALE Call",
         fields: [
           {:dest_addr, :text, label: "Destination Address (hex)", value: ""}
         ]}
      )
      model
    else
      model
    end
  end

  def handle_event({:dialog_result, :call_dialog, {:ok, %{dest_addr: addr}}}, model) do
    if model.active_rig_id do
      dest = parse_hex(addr)

      case CoreClient.ale_call(model.active_rig_id, dest,
             [waveform: model.waveform,
              tuner_time_ms: model.tuner_time_ms] ++ selected_net_opts(model)) do
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
  ## Handle Info — RX audio from RxMonitor
  ## ------------------------------------------------------------------

  defp sample_count(samples) when is_list(samples), do: length(samples)
  defp sample_count(samples) when is_binary(samples), do: div(byte_size(samples), 2)

  def handle_info({:rx_audio, _rig_id, samples}, model) do
    bins = DSP.fft_db(samples, @fft_size, @fft_window)
    WxMVU.GLCanvas.send_data(:ops_spectrogram, {:bins, bins})
    n = sample_count(samples)
    {:noreply, %{model | audio_chunks: model.audio_chunks + 1, audio_samples: model.audio_samples + n}}
  end

  def handle_info({:rx_audio, _rig_id, samples, _metadata}, model) do
    bins = DSP.fft_db(samples, @fft_size, @fft_window)
    WxMVU.GLCanvas.send_data(:ops_spectrogram, {:bins, bins})
    n = sample_count(samples)
    {:noreply, %{model | audio_chunks: model.audio_chunks + 1, audio_samples: model.audio_samples + n}}
  end

  def handle_info({:rx_monitor, :attached, _rig_id}, model) do
    {:noreply, %{model | rx_attached: true}}
  end

  def handle_info({:rx_monitor, :detached}, model) do
    {:noreply, %{model | rx_attached: false}}
  end

  def handle_info({:rx_monitor, :attach_failed, _reason}, model) do
    {:noreply, %{model | rx_attached: false}}
  end

  # --- Debug stats ---

  def handle_info(:stats_tick, model) do
    chunks = model.audio_chunks
    samples = model.audio_samples
    spc = div(samples, max(chunks, 1))
    text = "#{chunks} ch/s | #{samples} samp/s (#{spc} samp/ch)"
    Process.send_after(self(), :stats_tick, 1000)
    {:noreply, %{model | audio_chunks: 0, audio_samples: 0, stats_text: text}}
  end

  # --- ALE state changes from :pg group ---

  def handle_info({:ale_state_change, rig_id, state, info}, model) do
    if rig_id == model.active_rig_id do
      {:noreply, %{model | ale_state: state, ale_info: info}}
    else
      {:noreply, model}
    end
  end

  def handle_info({:ale_event, _rig_id, _event, _payload}, model) do
    # Could handle specific events like :call_failed, :link_terminated etc.
    {:noreply, model}
  end

  def handle_info(_msg, model), do: {:noreply, model}

  ## ------------------------------------------------------------------
  ## PG group helpers — subscribe to ALE events for a rig
  ## ------------------------------------------------------------------

  defp join_rig_events(rig_id) do
    group = {:minutemodem, :rig, rig_id}
    :pg.join(:minutemodem_pg, group, self())
  catch
    _, _ -> :ok
  end

  defp leave_rig_events(rig_id) do
    group = {:minutemodem, :rig, rig_id}
    :pg.leave(:minutemodem_pg, group, self())
  catch
    _, _ -> :ok
  end

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    [
      {:ensure_panel, :ops_root, {:page, :ops}, []}
    ] ++
      rig_selector(model) ++
      net_selector(model) ++
      waveform_controls(model) ++
      action_buttons(model) ++
      tuning_display(model) ++
      rig_status(model) ++
      debug_stats(model) ++
      spectrogram(model) ++
      [
        {:layout, :ops_root,
         {:vbox, [padding: 10],
          [
            {:hbox, [], [:ops_rig_label, :ops_rig_select, {:spacer, 10}, :ops_refresh]},
            {:spacer, 8},
            {:hbox, [], [:ops_net_label, :ops_net_select]},
            {:spacer, 8},
            {:hbox, [], [:ops_waveform_label, :ops_waveform, {:spacer, 20},
                         :ops_tuner_label, :ops_tuner_time]},
            {:spacer, 20},
            {:hbox, [align: :center], [:ops_scan, {:spacer, 10}, :ops_stop, {:spacer, 10}, :ops_call]},
            {:spacer, 15},
            :ops_freq_display,
            {:spacer, 3},
            :ops_channel_display,
            {:spacer, 3},
            :ops_scan_progress,
            {:spacer, 15},
            :ops_status,
            {:spacer, 10},
            :ops_timing_info,
            {:spacer, 5},
            :ops_debug_stats,
            {:spacer, 15},
            {:ops_spectrogram, proportion: 1, flag: :expand}
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

  defp net_selector(model) do
    net_names = ["Ad-hoc (default)" | Enum.map(model.nets, fn net ->
      ch_count = length(net.channels || [])
      dwell = get_in(net.timing_config, ["scan_dwell_ms"]) || "?"
      "#{net.name} (#{net.net_type}, #{ch_count} ch, #{dwell}ms)"
    end)]

    [
      {:ensure_widget, :ops_net_label, :static_text, :ops_root, label: "Network:"},
      {:ensure_widget, :ops_net_select, :choice, :ops_root, choices: net_names},
      {:set, :ops_net_select, items: net_names},
      {:set, :ops_net_select, selected: model.selected_net_index}
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

    call_enabled = model.ale_state in [:idle, :scanning]
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

  # -------------------------------------------------------------------
  # Tuning Display — frequency, channel name, scan progress
  # -------------------------------------------------------------------

  defp tuning_display(%{active_rig_id: nil}) do
    [
      {:ensure_widget, :ops_freq_display, :static_text, :ops_root, label: ""},
      {:ensure_widget, :ops_channel_display, :static_text, :ops_root, label: ""},
      {:ensure_widget, :ops_scan_progress, :static_text, :ops_root, label: ""}
    ]
  end

  defp tuning_display(%{ale_state: :scanning, ale_info: info}) when is_map(info) do
    freq_text = format_freq_display(Map.get(info, :freq_hz))
    channel_text = format_channel_display(Map.get(info, :channel))
    progress_text = format_scan_progress(info)

    [
      {:ensure_widget, :ops_freq_display, :static_text, :ops_root, label: freq_text},
      {:set, :ops_freq_display, label: freq_text},
      {:ensure_widget, :ops_channel_display, :static_text, :ops_root, label: channel_text},
      {:set, :ops_channel_display, label: channel_text},
      {:ensure_widget, :ops_scan_progress, :static_text, :ops_root, label: progress_text},
      {:set, :ops_scan_progress, label: progress_text}
    ]
  end

  defp tuning_display(%{ale_state: state, ale_info: info}) when state in [:calling, :lbt, :lbr, :responding, :linked] and is_map(info) do
    freq_text = format_freq_display(Map.get(info, :freq_hz))
    channel_text = case state do
      :linked -> "Linked"
      :calling -> "Calling"
      :lbt -> "LBT"
      :lbr -> "LBR"
      :responding -> "Responding"
      _ -> ""
    end

    [
      {:ensure_widget, :ops_freq_display, :static_text, :ops_root, label: freq_text},
      {:set, :ops_freq_display, label: freq_text},
      {:ensure_widget, :ops_channel_display, :static_text, :ops_root, label: channel_text},
      {:set, :ops_channel_display, label: channel_text},
      {:ensure_widget, :ops_scan_progress, :static_text, :ops_root, label: ""},
      {:set, :ops_scan_progress, label: ""}
    ]
  end

  defp tuning_display(_model) do
    [
      {:ensure_widget, :ops_freq_display, :static_text, :ops_root, label: "-- No frequency --"},
      {:set, :ops_freq_display, label: "-- No frequency --"},
      {:ensure_widget, :ops_channel_display, :static_text, :ops_root, label: ""},
      {:set, :ops_channel_display, label: ""},
      {:ensure_widget, :ops_scan_progress, :static_text, :ops_root, label: ""},
      {:set, :ops_scan_progress, label: ""}
    ]
  end

  defp format_freq_display(nil), do: "-- No frequency --"
  defp format_freq_display(freq_hz) when is_integer(freq_hz) do
    mhz = freq_hz / 1_000_000
    khz_part = rem(freq_hz, 1_000_000)
    # Format as "14.109.000 MHz" style for readability
    whole_mhz = div(freq_hz, 1_000_000)
    khz = div(khz_part, 1_000)
    hz = rem(khz_part, 1_000)
    freq_str = "#{whole_mhz}.#{String.pad_leading(Integer.to_string(khz), 3, "0")}.#{String.pad_leading(Integer.to_string(hz), 3, "0")}"
    "⏿  #{freq_str} MHz"
  end
  defp format_freq_display(freq_hz) when is_float(freq_hz) do
    format_freq_display(round(freq_hz))
  end

  defp format_channel_display(nil), do: ""
  defp format_channel_display(%{name: name, mode: mode}) when name != nil and name != "" do
    mode_str = mode |> to_string() |> String.upcase()
    "CH: #{name}  [#{mode_str}]"
  end
  defp format_channel_display(%{"name" => name, "mode" => mode}) when name != nil and name != "" do
    mode_str = mode |> to_string() |> String.upcase()
    "CH: #{name}  [#{mode_str}]"
  end
  defp format_channel_display(%{name: name}) when name != nil and name != "", do: "CH: #{name}"
  defp format_channel_display(_), do: ""

  defp format_scan_progress(info) do
    index = Map.get(info, :index, 0)
    num = Map.get(info, :num_channels, 0)
    dwell = Map.get(info, :scan_dwell_ms, 0)
    mode = Map.get(info, :scan_mode, :ale_4g)
    pending = Map.get(info, :pending_call, false)

    mode_str = case mode do
      :ale_2g -> "2G"
      :ale_3g -> "3G"
      :ale_4g -> "4G"
      other -> to_string(other)
    end

    # Determine sync vs async based on whether we have a net (multi-channel = sync)
    sync_str = if num > 1, do: "SYNC", else: "ASYNC"

    pending_str = if pending, do: "  ⏳ CALL PENDING", else: ""

    "Scan #{index + 1}/#{num}  |  #{mode_str} #{sync_str}  |  dwell #{dwell}ms#{pending_str}"
  end

  # -------------------------------------------------------------------
  # Rig Status
  # -------------------------------------------------------------------

  defp rig_status(%{active_rig_id: nil}) do
    [
      {:ensure_widget, :ops_status, :static_text, :ops_root,
       label: "No rig selected. Start a rig in the Rigs tab."},
      {:ensure_widget, :ops_timing_info, :static_text, :ops_root, label: ""}
    ]
  end

  defp rig_status(%{active_rig_id: _rig_id} = model) do
    status_text =
      case model.ale_state do
        :idle -> "IDLE"
        :scanning ->
          if pending_call?(model.ale_info), do: "SCANNING (call pending)", else: "SCANNING"
        :calling -> "CALLING #{format_info_addr(model.ale_info)} on #{format_info_freq(model.ale_info)}"
        :linked -> "LINKED to #{format_info_addr(model.ale_info)} on #{format_info_freq(model.ale_info)}"
        :lbt -> "LBT on #{format_info_freq(model.ale_info)}"
        :lbr -> "LBR on #{format_info_freq(model.ale_info)} from #{format_info_addr(model.ale_info)}"
        :responding -> "RESPONDING to #{format_info_addr(model.ale_info)} on #{format_info_freq(model.ale_info)}"
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

  defp debug_stats(model) do
    [
      {:ensure_widget, :ops_debug_stats, :static_text, :ops_root, label: model.stats_text},
      {:set, :ops_debug_stats, label: model.stats_text}
    ]
  end

  defp spectrogram(_model) do
    [
      {:ensure_gl_canvas, :ops_spectrogram, :ops_root,
        module: MinuteModemUI.Canvas.Spectrogram,
        size: {600, 200},
        opts: [
          history: 256,
          fft_size: div(@fft_size, 2),
          db_min: -100.0,
          db_max: -10.0,
          colormap: :viridis
        ]}
    ]
  end

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

  defp format_info_addr(addr) when is_integer(addr), do: format_addr(addr)
  defp format_info_addr(%{caller_addr: addr}), do: format_addr(addr)
  defp format_info_addr(%{remote_addr: addr}), do: format_addr(addr)
  defp format_info_addr(_), do: "?"

  defp format_info_freq(%{freq_hz: freq}) when is_integer(freq), do: format_freq_short(freq)
  defp format_info_freq(_), do: ""

  defp format_freq_short(freq_hz) when freq_hz >= 1_000_000 do
    mhz = freq_hz / 1_000_000
    "#{Float.round(mhz, 3)} MHz"
  end
  defp format_freq_short(freq_hz), do: "#{freq_hz} Hz"

  defp pending_call?(%{pending_call: true}), do: true
  defp pending_call?(_), do: false

  # Returns opts to pass to ale_scan/ale_call based on the selected net.
  # Index 0 = ad-hoc (no net_id, use defaults).
  # Index 1+ = actual net from the list.
  defp selected_net_opts(%{selected_net_index: 0}), do: []
  defp selected_net_opts(%{selected_net_index: idx, nets: nets}) do
    case Enum.at(nets, idx - 1) do
      nil -> []
      net -> [net_id: net.id]
    end
  end

  defp load_nets do
    case CoreClient.list_nets() do
      {:error, _} -> []
      nets when is_list(nets) -> nets
      _ -> []
    end
  end
end
