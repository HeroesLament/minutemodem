defmodule MinuteModemUI.Scenes.Nets do
  @moduledoc """
  Nets management scene.

  Configure ALE networks including channels (frequencies) and members (stations).
  """

  use WxMVU.Scene

  alias MinuteModemUI.CoreClient

  @net_types ["ale_2g", "ale_3g", "ale_4g"]
  @channel_modes ["usb", "lsb", "am"]
  @member_roles ["member", "net_control", "relay"]
  @bands ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m"]

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    nets = load_nets()

    %{
      nets: nets,
      selected_net_id: first_net_id(nets),
      form_mode: nil,
      form: default_form(),
      channel_edit_index: nil,
      member_edit_index: nil
    }
  end

  defp default_form do
    %{
      name: "",
      net_type: "ale_4g",
      enabled: true,
      channels: [],
      members: [],
      timing_config: %{},
      # Channel form fields
      ch_freq_mhz: "",
      ch_name: "",
      ch_band: "40m",
      ch_mode: "usb",
      # Member form fields
      mem_addr: "",
      mem_name: "",
      mem_callsign: "",
      mem_role: "member"
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event - List operations
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :nets_list, :change, index}, model) do
    net = Enum.at(model.nets, index)
    %{model | selected_net_id: net && net.id}
  end

  def handle_event({:ui_event, :nets_refresh, :click}, model) do
    nets = load_nets()
    selected = if Enum.any?(nets, &(&1.id == model.selected_net_id)) do
      model.selected_net_id
    else
      first_net_id(nets)
    end
    %{model | nets: nets, selected_net_id: selected}
  end

  def handle_event({:ui_event, :nets_new, :click}, model) do
    %{model | form_mode: :new, form: default_form()}
  end

  def handle_event({:ui_event, :nets_edit, :click}, model) do
    if model.selected_net_id do
      net = Enum.find(model.nets, &(&1.id == model.selected_net_id))
      if net do
        %{model | form_mode: :edit, form: net_to_form(net)}
      else
        model
      end
    else
      model
    end
  end

  def handle_event({:ui_event, :nets_delete, :click}, model) do
    if model.selected_net_id do
      case CoreClient.delete_net(model.selected_net_id) do
        {:ok, _} ->
          nets = load_nets()
          %{model | nets: nets, selected_net_id: first_net_id(nets)}
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

  def handle_event({:ui_event, :form_name, :change, value}, model) do
    put_in(model, [:form, :name], value)
  end

  def handle_event({:ui_event, :form_net_type, :change, index}, model) do
    net_type = Enum.at(@net_types, index) || "ale_4g"
    put_in(model, [:form, :net_type], net_type)
  end

  def handle_event({:ui_event, :form_enabled, :change, value}, model) do
    put_in(model, [:form, :enabled], value)
  end

  ## ------------------------------------------------------------------
  ## Handle Event - Channel editing
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :form_ch_freq, :change, value}, model) do
    put_in(model, [:form, :ch_freq_mhz], value)
  end

  def handle_event({:ui_event, :form_ch_name, :change, value}, model) do
    put_in(model, [:form, :ch_name], value)
  end

  def handle_event({:ui_event, :form_ch_band, :change, index}, model) do
    band = Enum.at(@bands, index) || "40m"
    put_in(model, [:form, :ch_band], band)
  end

  def handle_event({:ui_event, :form_ch_mode, :change, index}, model) do
    mode = Enum.at(@channel_modes, index) || "usb"
    put_in(model, [:form, :ch_mode], mode)
  end

  def handle_event({:ui_event, :form_ch_add, :click}, model) do
    freq_mhz = parse_float(model.form.ch_freq_mhz)

    if freq_mhz do
      channel = %{
        "freq_hz" => round(freq_mhz * 1_000_000),
        "name" => model.form.ch_name,
        "band" => model.form.ch_band,
        "mode" => model.form.ch_mode
      }

      channels = model.form.channels ++ [channel]

      model
      |> put_in([:form, :channels], channels)
      |> put_in([:form, :ch_freq_mhz], "")
      |> put_in([:form, :ch_name], "")
    else
      model
    end
  end

  def handle_event({:ui_event, :form_ch_remove, :click}, model) do
    case model.channel_edit_index do
      nil -> model
      idx ->
        channels = List.delete_at(model.form.channels, idx)
        model
        |> put_in([:form, :channels], channels)
        |> Map.put(:channel_edit_index, nil)
    end
  end

  def handle_event({:ui_event, :channels_list, :change, index}, model) do
    %{model | channel_edit_index: index}
  end

  ## ------------------------------------------------------------------
  ## Handle Event - Member editing
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :form_mem_addr, :change, value}, model) do
    put_in(model, [:form, :mem_addr], value)
  end

  def handle_event({:ui_event, :form_mem_name, :change, value}, model) do
    put_in(model, [:form, :mem_name], value)
  end

  def handle_event({:ui_event, :form_mem_callsign, :change, value}, model) do
    put_in(model, [:form, :mem_callsign], value)
  end

  def handle_event({:ui_event, :form_mem_role, :change, index}, model) do
    role = Enum.at(@member_roles, index) || "member"
    put_in(model, [:form, :mem_role], role)
  end

  def handle_event({:ui_event, :form_mem_add, :click}, model) do
    addr = parse_hex(model.form.mem_addr)

    if addr do
      member = %{
        "addr" => addr,
        "name" => model.form.mem_name,
        "callsign" => model.form.mem_callsign,
        "role" => model.form.mem_role
      }

      members = model.form.members ++ [member]

      model
      |> put_in([:form, :members], members)
      |> put_in([:form, :mem_addr], "")
      |> put_in([:form, :mem_name], "")
      |> put_in([:form, :mem_callsign], "")
    else
      model
    end
  end

  def handle_event({:ui_event, :form_mem_remove, :click}, model) do
    case model.member_edit_index do
      nil -> model
      idx ->
        members = List.delete_at(model.form.members, idx)
        model
        |> put_in([:form, :members], members)
        |> Map.put(:member_edit_index, nil)
    end
  end

  def handle_event({:ui_event, :members_list, :change, index}, model) do
    %{model | member_edit_index: index}
  end

  ## ------------------------------------------------------------------
  ## Handle Event - Form save/cancel
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :form_save, :click}, model) do
    attrs = form_to_attrs(model.form)

    result = case model.form_mode do
      :new -> CoreClient.create_net(attrs)
      :edit -> CoreClient.update_net(model.selected_net_id, attrs)
    end

    case result do
      {:ok, net} ->
        nets = load_nets()
        %{model |
          form_mode: nil,
          nets: nets,
          selected_net_id: net.id,
          channel_edit_index: nil,
          member_edit_index: nil
        }
      {:error, _} ->
        model
    end
  end

  def handle_event({:ui_event, :form_cancel, :click}, model) do
    nets = load_nets()
    %{model |
      form_mode: nil,
      nets: nets,
      channel_edit_index: nil,
      member_edit_index: nil
    }
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    base_intents = [
      {:ensure_panel, :nets_root, {:page, :nets}, []}
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
    net_items = Enum.map(model.nets, fn net ->
      ch_count = length(net.channels || [])
      mem_count = length(net.members || [])
      enabled = if net.enabled, do: "✓", else: "○"
      "#{enabled} #{net.name} (#{net.net_type}) - #{ch_count} ch, #{mem_count} members"
    end)

    selected = Enum.find_index(model.nets, &(&1.id == model.selected_net_id)) || 0

    [
      {:ensure_widget, :nets_new, :button, :nets_root, label: "New"},
      {:ensure_widget, :nets_edit, :button, :nets_root, label: "Edit"},
      {:ensure_widget, :nets_delete, :button, :nets_root, label: "Delete"},
      {:ensure_widget, :nets_refresh, :button, :nets_root, label: "Refresh"},

      {:ensure_widget, :nets_list, :list_box, :nets_root, choices: net_items},
      {:set, :nets_list, items: net_items},
      {:set, :nets_list, selected: selected},

      {:layout, :nets_root,
       {:vbox, [padding: 5],
        [
          {:hbox, [],
           [
             :nets_new,
             :nets_edit,
             :nets_delete,
             {:spacer, 20},
             :nets_refresh
           ]},
          {:nets_list, proportion: 1, flag: :expand}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## Form View
  ## ------------------------------------------------------------------

  defp form_view(model) do
    form = model.form
    title = if model.form_mode == :new, do: "New Net", else: "Edit Net"

    channel_items = Enum.map(form.channels, fn ch ->
      freq_mhz = (ch["freq_hz"] || 0) / 1_000_000
      "#{ch["name"] || "?"} - #{:erlang.float_to_binary(freq_mhz, decimals: 3)} MHz (#{ch["band"] || "?"}, #{ch["mode"] || "?"})"
    end)

    member_items = Enum.map(form.members, fn m ->
      addr_hex = Integer.to_string(m["addr"] || 0, 16)
      "0x#{addr_hex} - #{m["name"] || "?"} (#{m["callsign"] || "?"}) [#{m["role"] || "?"}]"
    end)

    popup_panel = [
      {:ensure_panel, :form_popup, :nets_root, [border: :simple]}
    ]

    base_widgets = [
      {:ensure_widget, :form_title, :static_text, :form_popup, label: title},

      {:ensure_widget, :form_name_label, :static_text, :form_popup, label: "Name:"},
      {:ensure_widget, :form_name, :text_ctrl, :form_popup, value: form.name},

      {:ensure_widget, :form_net_type_label, :static_text, :form_popup, label: "Type:"},
      {:ensure_widget, :form_net_type, :choice, :form_popup, choices: @net_types},
      {:set, :form_net_type, selected: Enum.find_index(@net_types, &(&1 == form.net_type)) || 0}
    ]

    channel_widgets = [
      {:ensure_widget, :channels_header, :static_text, :form_popup, label: "── Channels ──"},
      {:ensure_widget, :channels_list, :list_box, :form_popup, choices: channel_items, size: {400, 100}},
      {:set, :channels_list, items: channel_items},

      {:ensure_widget, :form_ch_freq_label, :static_text, :form_popup, label: "Freq (MHz):"},
      {:ensure_widget, :form_ch_freq, :text_ctrl, :form_popup, value: form.ch_freq_mhz, size: {80, -1}},

      {:ensure_widget, :form_ch_name_label, :static_text, :form_popup, label: "Name:"},
      {:ensure_widget, :form_ch_name, :text_ctrl, :form_popup, value: form.ch_name, size: {100, -1}},

      {:ensure_widget, :form_ch_band_label, :static_text, :form_popup, label: "Band:"},
      {:ensure_widget, :form_ch_band, :choice, :form_popup, choices: @bands},
      {:set, :form_ch_band, selected: Enum.find_index(@bands, &(&1 == form.ch_band)) || 0},

      {:ensure_widget, :form_ch_mode_label, :static_text, :form_popup, label: "Mode:"},
      {:ensure_widget, :form_ch_mode, :choice, :form_popup, choices: @channel_modes},
      {:set, :form_ch_mode, selected: Enum.find_index(@channel_modes, &(&1 == form.ch_mode)) || 0},

      {:ensure_widget, :form_ch_add, :button, :form_popup, label: "Add Channel"},
      {:ensure_widget, :form_ch_remove, :button, :form_popup, label: "Remove"}
    ]

    member_widgets = [
      {:ensure_widget, :members_header, :static_text, :form_popup, label: "── Members ──"},
      {:ensure_widget, :members_list, :list_box, :form_popup, choices: member_items, size: {400, 100}},
      {:set, :members_list, items: member_items},

      {:ensure_widget, :form_mem_addr_label, :static_text, :form_popup, label: "Addr (hex):"},
      {:ensure_widget, :form_mem_addr, :text_ctrl, :form_popup, value: form.mem_addr, size: {80, -1}},

      {:ensure_widget, :form_mem_name_label, :static_text, :form_popup, label: "Name:"},
      {:ensure_widget, :form_mem_name, :text_ctrl, :form_popup, value: form.mem_name, size: {100, -1}},

      {:ensure_widget, :form_mem_callsign_label, :static_text, :form_popup, label: "Callsign:"},
      {:ensure_widget, :form_mem_callsign, :text_ctrl, :form_popup, value: form.mem_callsign, size: {80, -1}},

      {:ensure_widget, :form_mem_role_label, :static_text, :form_popup, label: "Role:"},
      {:ensure_widget, :form_mem_role, :choice, :form_popup, choices: @member_roles},
      {:set, :form_mem_role, selected: Enum.find_index(@member_roles, &(&1 == form.mem_role)) || 0},

      {:ensure_widget, :form_mem_add, :button, :form_popup, label: "Add Member"},
      {:ensure_widget, :form_mem_remove, :button, :form_popup, label: "Remove"}
    ]

    button_widgets = [
      {:ensure_widget, :form_save, :button, :form_popup, label: "Save"},
      {:ensure_widget, :form_cancel, :button, :form_popup, label: "Cancel"}
    ]

    layout = {:layout, :form_popup,
      {:vbox, [padding: 15],
       [
         {:hbox, [], [:form_title]},
         {:hbox, [], [:form_name_label, :form_name]},
         {:hbox, [], [:form_net_type_label, :form_net_type]},
         {:spacer, 10},
         {:hbox, [], [:channels_header]},
         {:channels_list, proportion: 0},
         {:hbox, [],
          [:form_ch_freq_label, :form_ch_freq,
           :form_ch_name_label, :form_ch_name,
           :form_ch_band_label, :form_ch_band,
           :form_ch_mode_label, :form_ch_mode]},
         {:hbox, [], [:form_ch_add, :form_ch_remove]},
         {:spacer, 10},
         {:hbox, [], [:members_header]},
         {:members_list, proportion: 0},
         {:hbox, [],
          [:form_mem_addr_label, :form_mem_addr,
           :form_mem_name_label, :form_mem_name,
           :form_mem_callsign_label, :form_mem_callsign,
           :form_mem_role_label, :form_mem_role]},
         {:hbox, [], [:form_mem_add, :form_mem_remove]},
         {:spacer, 15},
         {:hbox, [], [:form_save, :form_cancel]}
       ]}}

    outer_layout = {:layout, :nets_root,
     {:vbox, [],
      [
        {:spacer, 10},
        {:form_popup, proportion: 0, flag: [:align_center_horizontal]},
        {:spacer, 10}
      ]}}

    popup_panel ++ base_widgets ++ channel_widgets ++ member_widgets ++ button_widgets ++ [layout, outer_layout]
  end

  ## ------------------------------------------------------------------
  ## Form <-> Data Conversion
  ## ------------------------------------------------------------------

  defp net_to_form(net) do
    %{
      name: net.name || "",
      net_type: net.net_type || "ale_4g",
      enabled: net.enabled,
      channels: net.channels || [],
      members: net.members || [],
      timing_config: net.timing_config || %{},
      ch_freq_mhz: "",
      ch_name: "",
      ch_band: "40m",
      ch_mode: "usb",
      mem_addr: "",
      mem_name: "",
      mem_callsign: "",
      mem_role: "member"
    }
  end

  defp form_to_attrs(form) do
    %{
      name: form.name,
      net_type: form.net_type,
      enabled: form.enabled,
      channels: form.channels,
      members: form.members,
      timing_config: form.timing_config
    }
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp load_nets do
    case CoreClient.list_nets() do
      {:error, _} -> []
      nets when is_list(nets) -> nets
      _ -> []
    end
  end

  defp first_net_id([]), do: nil
  defp first_net_id([net | _]), do: net.id

  defp parse_hex(nil), do: nil
  defp parse_hex(""), do: nil
  defp parse_hex(str) when is_binary(str) do
    str = String.trim(str)
    str = String.replace_prefix(str, "0x", "")
    str = String.replace_prefix(str, "0X", "")

    case Integer.parse(str, 16) do
      {val, ""} -> val
      {val, _} -> val
      :error -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil
  defp parse_float(str) when is_binary(str) do
    case Float.parse(String.trim(str)) do
      {val, _} -> val
      :error -> nil
    end
  end
end
