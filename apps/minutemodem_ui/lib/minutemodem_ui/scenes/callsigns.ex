defmodule MinuteModemUI.Scenes.Callsigns do
  @moduledoc """
  Callsigns directory scene.

  Manage known station addresses with LQA history.
  """

  use WxMVU.Scene

  alias MinuteModemUI.CoreClient

  @sources ["manual", "sounding", "inbound_call", "imported"]

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    callsigns = load_callsigns()

    %{
      callsigns: callsigns,
      selected_id: first_id(callsigns),
      form_mode: nil,
      form: default_form(),
      soundings: []
    }
  end

  defp default_form do
    %{
      addr: "",
      name: "",
      callsign: "",
      source: "manual",
      notes: ""
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event - List operations
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :callsigns_list, :change, index}, model) do
    callsign = Enum.at(model.callsigns, index)
    new_model = %{model | selected_id: callsign && callsign.id}

    if callsign do
      soundings = load_soundings(callsign.id)
      %{new_model | soundings: soundings}
    else
      %{new_model | soundings: []}
    end
  end

  def handle_event({:ui_event, :callsigns_refresh, :click}, model) do
    callsigns = load_callsigns()
    selected = if Enum.any?(callsigns, &(&1.id == model.selected_id)) do
      model.selected_id
    else
      first_id(callsigns)
    end

    soundings = if selected, do: load_soundings(selected), else: []
    %{model | callsigns: callsigns, selected_id: selected, soundings: soundings}
  end

  def handle_event({:ui_event, :callsigns_new, :click}, model) do
    %{model | form_mode: :new, form: default_form()}
  end

  def handle_event({:ui_event, :callsigns_edit, :click}, model) do
    if model.selected_id do
      callsign = Enum.find(model.callsigns, &(&1.id == model.selected_id))
      if callsign do
        %{model | form_mode: :edit, form: callsign_to_form(callsign)}
      else
        model
      end
    else
      model
    end
  end

  def handle_event({:ui_event, :callsigns_delete, :click}, model) do
    if model.selected_id do
      case CoreClient.delete_callsign(model.selected_id) do
        {:ok, _} ->
          callsigns = load_callsigns()
          %{model | callsigns: callsigns, selected_id: first_id(callsigns), soundings: []}
        {:error, _} ->
          model
      end
    else
      model
    end
  end

  ## ------------------------------------------------------------------
  ## Handle Event - Form fields
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :form_addr, :change, value}, model) do
    put_in(model, [:form, :addr], value)
  end

  def handle_event({:ui_event, :form_name, :change, value}, model) do
    put_in(model, [:form, :name], value)
  end

  def handle_event({:ui_event, :form_callsign, :change, value}, model) do
    put_in(model, [:form, :callsign], value)
  end

  def handle_event({:ui_event, :form_source, :change, index}, model) do
    source = Enum.at(@sources, index) || "manual"
    put_in(model, [:form, :source], source)
  end

  def handle_event({:ui_event, :form_notes, :change, value}, model) do
    put_in(model, [:form, :notes], value)
  end

  ## ------------------------------------------------------------------
  ## Handle Event - Form save/cancel
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :form_save, :click}, model) do
    attrs = form_to_attrs(model.form)

    result = case model.form_mode do
      :new -> CoreClient.create_callsign(attrs)
      :edit -> CoreClient.update_callsign(model.selected_id, attrs)
    end

    case result do
      {:ok, callsign} ->
        callsigns = load_callsigns()
        %{model |
          form_mode: nil,
          callsigns: callsigns,
          selected_id: callsign.id
        }
      {:error, _} ->
        model
    end
  end

  def handle_event({:ui_event, :form_cancel, :click}, model) do
    callsigns = load_callsigns()
    %{model | form_mode: nil, callsigns: callsigns}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    base_intents = [
      {:ensure_panel, :callsigns_root, {:page, :callsigns}, []}
    ]

    content_intents = if model.form_mode do
      form_view(model)
    else
      list_view(model)
    end

    base_intents ++ content_intents
  end

  ## ------------------------------------------------------------------
  ## List View
  ## ------------------------------------------------------------------

  defp list_view(model) do
    callsign_items = Enum.map(model.callsigns, fn cs ->
      addr_hex = Integer.to_string(cs.addr, 16) |> String.pad_leading(4, "0")
      name_part = if cs.name && cs.name != "", do: cs.name, else: cs.callsign || "?"
      heard = if cs.heard_count, do: "(#{cs.heard_count}x)", else: ""
      source_icon = source_icon(cs.source)
      "#{source_icon} 0x#{addr_hex} #{name_part} #{heard}"
    end)

    selected_idx = Enum.find_index(model.callsigns, &(&1.id == model.selected_id)) || 0

    sounding_items = Enum.map(model.soundings, fn s ->
      freq_mhz = (s.freq_hz || 0) / 1_000_000
      snr = if s.snr_db, do: "#{Float.round(s.snr_db, 1)} dB", else: "?"
      time = if s.timestamp, do: Calendar.strftime(s.timestamp, "%H:%M:%S"), else: "?"
      "#{time} | #{:erlang.float_to_binary(freq_mhz, decimals: 3)} MHz | SNR: #{snr}"
    end)

    [
      {:ensure_widget, :callsigns_new, :button, :callsigns_root, label: "New"},
      {:ensure_widget, :callsigns_edit, :button, :callsigns_root, label: "Edit"},
      {:ensure_widget, :callsigns_delete, :button, :callsigns_root, label: "Delete"},
      {:ensure_widget, :callsigns_refresh, :button, :callsigns_root, label: "Refresh"},

      {:ensure_widget, :callsigns_list, :list_box, :callsigns_root, choices: callsign_items},
      {:set, :callsigns_list, items: callsign_items},
      {:set, :callsigns_list, selected: selected_idx},

      {:ensure_widget, :soundings_label, :static_text, :callsigns_root, label: "Recent Soundings:"},
      {:ensure_widget, :soundings_list, :list_box, :callsigns_root, choices: sounding_items},
      {:set, :soundings_list, items: sounding_items},

      {:layout, :callsigns_root,
       {:vbox, [padding: 5],
        [
          {:hbox, [],
           [
             :callsigns_new,
             :callsigns_edit,
             :callsigns_delete,
             {:spacer, 20},
             :callsigns_refresh
           ]},
          {:callsigns_list, proportion: 1, flag: :expand},
          {:spacer, 10},
          :soundings_label,
          {:soundings_list, proportion: 1, flag: :expand}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## Form View
  ## ------------------------------------------------------------------

  defp form_view(model) do
    form = model.form
    title = if model.form_mode == :new, do: "New Callsign", else: "Edit Callsign"
    source_idx = Enum.find_index(@sources, &(&1 == form.source)) || 0

    popup_panel = [
      {:ensure_panel, :form_popup, :callsigns_root, [border: :simple]}
    ]

    widgets = [
      {:ensure_widget, :form_title, :static_text, :form_popup, label: title},

      {:ensure_widget, :form_addr_label, :static_text, :form_popup, label: "Address (hex):"},
      {:ensure_widget, :form_addr, :text_ctrl, :form_popup, value: form.addr},

      {:ensure_widget, :form_name_label, :static_text, :form_popup, label: "Name:"},
      {:ensure_widget, :form_name, :text_ctrl, :form_popup, value: form.name},

      {:ensure_widget, :form_callsign_label, :static_text, :form_popup, label: "Callsign:"},
      {:ensure_widget, :form_callsign, :text_ctrl, :form_popup, value: form.callsign},

      {:ensure_widget, :form_source_label, :static_text, :form_popup, label: "Source:"},
      {:ensure_widget, :form_source, :choice, :form_popup, choices: @sources},
      {:set, :form_source, selected: source_idx},

      {:ensure_widget, :form_notes_label, :static_text, :form_popup, label: "Notes:"},
      {:ensure_widget, :form_notes, :text_ctrl, :form_popup, value: form.notes, style: :multiline, size: {300, 60}},

      {:ensure_widget, :form_save, :button, :form_popup, label: "Save"},
      {:ensure_widget, :form_cancel, :button, :form_popup, label: "Cancel"}
    ]

    layout = {:layout, :form_popup,
      {:vbox, [padding: 15],
       [
         {:hbox, [], [:form_title]},
         {:hbox, [], [:form_addr_label, :form_addr]},
         {:hbox, [], [:form_name_label, :form_name]},
         {:hbox, [], [:form_callsign_label, :form_callsign]},
         {:hbox, [], [:form_source_label, :form_source]},
         {:hbox, [], [:form_notes_label]},
         :form_notes,
         {:spacer, 15},
         {:hbox, [], [:form_save, :form_cancel]}
       ]}}

    outer_layout = {:layout, :callsigns_root,
     {:vbox, [],
      [
        {:spacer, 10},
        {:form_popup, proportion: 0, flag: [:align_center_horizontal]},
        {:spacer, 10}
      ]}}

    # Destroy list view widgets when showing form
    destroy_list = [
      {:destroy_widget, :callsigns_new, :button},
      {:destroy_widget, :callsigns_edit, :button},
      {:destroy_widget, :callsigns_delete, :button},
      {:destroy_widget, :callsigns_refresh, :button},
      {:destroy_widget, :callsigns_list, :list_box},
      {:destroy_widget, :soundings_label, :static_text},
      {:destroy_widget, :soundings_list, :list_box}
    ]

    destroy_list ++ popup_panel ++ widgets ++ [layout, outer_layout]
  end

  ## ------------------------------------------------------------------
  ## Form <-> Data Conversion
  ## ------------------------------------------------------------------

  defp callsign_to_form(cs) do
    %{
      addr: Integer.to_string(cs.addr, 16),
      name: cs.name || "",
      callsign: cs.callsign || "",
      source: cs.source || "manual",
      notes: cs.notes || ""
    }
  end

  defp form_to_attrs(form) do
    %{
      addr: parse_hex(form.addr),
      name: form.name,
      callsign: form.callsign,
      source: form.source,
      notes: form.notes
    }
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp load_callsigns do
    case CoreClient.list_callsigns() do
      {:error, _} -> []
      callsigns when is_list(callsigns) -> callsigns
      _ -> []
    end
  end

  defp load_soundings(callsign_id) do
    case CoreClient.get_callsign_soundings(callsign_id, limit: 50) do
      {:error, _} -> []
      soundings when is_list(soundings) -> soundings
      _ -> []
    end
  end

  defp first_id([]), do: nil
  defp first_id([cs | _]), do: cs.id

  defp source_icon("manual"), do: "✎"
  defp source_icon("sounding"), do: "📡"
  defp source_icon("inbound_call"), do: "📞"
  defp source_icon("imported"), do: "📥"
  defp source_icon(_), do: "?"

  defp parse_hex(nil), do: nil
  defp parse_hex(""), do: nil
  defp parse_hex(str) when is_binary(str) do
    str = String.trim(str)
    str = String.replace_prefix(str, "0x", "")
    str = String.replace_prefix(str, "0X", "")

    case Integer.parse(str, 16) do
      {val, _} -> val
      :error -> nil
    end
  end
end
