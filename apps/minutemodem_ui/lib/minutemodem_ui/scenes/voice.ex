defmodule MinuteModemUI.Scenes.Voice do
  @moduledoc """
  Voice scene — operator voice interface.

  Pure view layer. Owns a `Voice.Client` and routes its notifications
  through `handle_info` → `handle_event` → model → `view/1`.

  Three controls: STOP (left), TX (center), START (right).
  Plus a rig selector and speaker device selector.
  """

  use WxMVU.Scene

  alias MinuteModemUI.Voice.Client, as: VoiceClient
  alias MinuteModemUI.CoreClient

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    {:ok, client} = VoiceClient.start_link(owner: self())

    running = safe_list_running()
    audio_devices = safe_list_audio_devices()
    output_devices = Enum.filter(audio_devices, &(&1.direction in [:output, :duplex]))

    default_speaker = Enum.find(output_devices, &(&1.default_device))

    %{
      client: client,
      running_rigs: running,
      selected_rig_id: nil,
      output_devices: output_devices,
      selected_speaker_name: default_speaker && default_speaker.name,

      # Mirrored from Voice.Client
      active: false,
      tx_held: false,
      tx_status: nil
    }
  end

  ## ------------------------------------------------------------------
  ## Derived State
  ## ------------------------------------------------------------------

  defp can_start?(model), do: model.selected_rig_id != nil and not model.active
  defp can_stop?(model), do: model.active
  defp can_tx?(model), do: model.active

  defp status_text(model) do
    cond do
      model.selected_rig_id == nil -> "Select a rig"
      not model.active -> "Ready — press START"
      model.tx_held and model.tx_status == :voice -> "TX"
      model.tx_held -> "TX (keying...)"
      model.tx_status == :busy -> "RX — TX busy"
      model.active -> "RX"
      true -> ""
    end
  end

  ## ------------------------------------------------------------------
  ## Handle Info
  ## ------------------------------------------------------------------

  def handle_info({:voice, _, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:voice, _} = msg, model), do: {:noreply, handle_event(msg, model)}

  ## ------------------------------------------------------------------
  ## Handle Event — UI
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :voice_rig_select, :change, index}, model) do
    rig_id = Enum.at(model.running_rigs, index)
    %{model | selected_rig_id: rig_id}
  end

  def handle_event({:ui_event, :voice_refresh, :click}, model) do
    running = safe_list_running()
    %{model | running_rigs: running}
  end

  def handle_event({:ui_event, :voice_speaker_select, :change, index}, model) do
    device = Enum.at(model.output_devices, index)
    %{model | selected_speaker_name: device && device.name}
  end

  def handle_event({:ui_event, :voice_start, :click}, model) do
    if can_start?(model) do
      VoiceClient.start_voice(model.client, model.selected_rig_id, model.selected_speaker_name)
    end

    model
  end

  def handle_event({:ui_event, :voice_stop, :click}, model) do
    if can_stop?(model) do
      VoiceClient.stop_voice(model.client)
    end

    model
  end

  def handle_event({:ui_event, :voice_tx, :click}, model) do
    if can_tx?(model) do
      if model.tx_held do
        VoiceClient.tx_off(model.client)
      else
        VoiceClient.tx_on(model.client)
      end
    end

    model
  end

  ## ------------------------------------------------------------------
  ## Handle Event — Voice.Client notifications
  ## ------------------------------------------------------------------

  def handle_event({:voice, :started, _rig_id}, model) do
    %{model | active: true}
  end

  def handle_event({:voice, :stopped}, model) do
    %{model | active: false, tx_held: false, tx_status: nil}
  end

  def handle_event({:voice, :start_failed, _reason}, model) do
    %{model | active: false}
  end

  def handle_event({:voice, :tx_on}, model) do
    %{model | tx_held: true}
  end

  def handle_event({:voice, :tx_off}, model) do
    %{model | tx_held: false}
  end

  def handle_event({:voice, :tx_status, owner}, model) do
    %{model | tx_status: owner}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    status = status_text(model)
    tx_label = if model.tx_held, do: "◉ TX", else: "TX"

    [
      {:ensure_panel, :voice_root, {:page, :voice}, []}
    ] ++
      rig_selector(model) ++
      speaker_selector(model) ++
      [
        # --- Three buttons: STOP / TX / START ---

        {:ensure_widget, :voice_stop, :button, :voice_root,
         label: "STOP", size: {100, 60}},
        {:set, :voice_stop, enabled: can_stop?(model)},

        {:ensure_widget, :voice_tx, :button, :voice_root,
         label: tx_label, size: {120, 60}},
        {:set, :voice_tx, label: tx_label},
        {:set, :voice_tx, enabled: can_tx?(model)},

        {:ensure_widget, :voice_start, :button, :voice_root,
         label: "START", size: {100, 60}},
        {:set, :voice_start, enabled: can_start?(model)},

        # --- Status ---

        {:ensure_widget, :voice_status, :static_text, :voice_root, label: status},
        {:set, :voice_status, label: status},

        # --- Layout ---

        {:layout, :voice_root,
         {:vbox, [padding: 20],
          [
            {:hbox, [],
             [:voice_rig_label, :voice_rig_select, {:spacer, 10}, :voice_refresh]},
            {:spacer, 10},
            {:hbox, [],
             [:voice_speaker_label, :voice_speaker_select]},
            {:spacer, 20},
            {:hbox, [align: :center],
             [
               :voice_stop,
               {:spacer, 15},
               :voice_tx,
               {:spacer, 15},
               :voice_start
             ]},
            {:spacer, 20},
            {:hbox, [align: :center], [:voice_status]}
          ]}}
      ]
  end

  defp rig_selector(model) do
    rig_names = Enum.map(model.running_rigs, &rig_display_name/1)
    selected = Enum.find_index(model.running_rigs, &(&1 == model.selected_rig_id)) || -1

    [
      {:ensure_widget, :voice_rig_label, :static_text, :voice_root, label: "Rig:"},
      {:ensure_widget, :voice_rig_select, :choice, :voice_root, choices: rig_names},
      {:set, :voice_rig_select, items: rig_names},
      {:set, :voice_rig_select, selected: selected},
      {:ensure_widget, :voice_refresh, :button, :voice_root, label: "↻"}
    ]
  end

  defp speaker_selector(model) do
    device_names = Enum.map(model.output_devices, & &1.name)
    selected = Enum.find_index(model.output_devices, &(&1.name == model.selected_speaker_name)) || -1

    [
      {:ensure_widget, :voice_speaker_label, :static_text, :voice_root, label: "Speaker:"},
      {:ensure_widget, :voice_speaker_select, :choice, :voice_root, choices: device_names},
      {:set, :voice_speaker_select, items: device_names},
      {:set, :voice_speaker_select, selected: selected}
    ]
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp rig_display_name(rig_id), do: String.slice(rig_id, 0, 8)

  defp safe_list_running do
    CoreClient.list_running_rigs()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_list_audio_devices do
    CoreClient.list_audio_devices()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
