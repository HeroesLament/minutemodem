defmodule MinuteModemUI.Scenes.Rigs do
  @moduledoc """
  Rigs management scene.

  Displays all rigs from the database with controls to
  create, edit, delete, and start/stop rigs.

  Uses an embedded form panel (not modal dialog) so that
  simnet fields can dynamically appear/disappear based on rig type.

  Communicates with core via MinuteModemUI.CoreClient (distributed calls).
  """

  use WxMVU.Scene

  alias MinuteModemUI.CoreClient

  @rig_types ["test", "hf", "hf_rx", "vhf"]
  @protocols ["ale_2g", "ale_3g", "ale_4g", "stanag_5066", "packet", "aprs"]
  @control_types ["simulator", "rigctld", "flrig"]
  @antenna_types ["dipole", "vertical", "inverted_v", "yagi", "loop"]

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    # Auto-refresh every 5 seconds
    :timer.send_interval(5000, self(), :refresh_rigs)

    rigs = load_rigs()

    %{
      rigs: rigs,
      selected_rig_id: first_rig_id(rigs),
      audio_devices: CoreClient.list_audio_devices(),
      form_mode: nil,
      form: default_form()
    }
  end

  defp default_form do
    %{
      name: "",
      rig_type: "test",
      protocol_stack: "ale_4g",
      self_addr: "1234",
      control_type: "simulator",
      rx_audio: "(None)",
      tx_audio: "(None)",
      dte_port: "3000",
      # Simnet fields
      latitude: "64.8378",
      longitude: "-147.7164",
      antenna_type: "dipole",
      antenna_height: "0.5",
      tx_power: "100",
      # Rigctld fields
      rigctld_model: "1",
      rigctld_device: "",
      rigctld_baud: "9600",
      rigctld_civaddr: "",
      rigctld_port: "4532"
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event
  ## ------------------------------------------------------------------

  # List selection
  def handle_event({:ui_event, :rigs_list, :change, index}, model) do
    rig = Enum.at(model.rigs, index)
    %{model | selected_rig_id: rig && rig.id}
  end

  # Toolbar buttons
  def handle_event({:ui_event, :rigs_refresh, :click}, model) do
    rigs = load_rigs()
    selected = if Enum.any?(rigs, &(&1.id == model.selected_rig_id)) do
      model.selected_rig_id
    else
      first_rig_id(rigs)
    end

    %{model | rigs: rigs, selected_rig_id: selected, audio_devices: CoreClient.list_audio_devices()}
  end

  def handle_event({:ui_event, :rigs_new, :click}, model) do
    %{model |
      form_mode: :new,
      form: default_form(),
      audio_devices: CoreClient.list_audio_devices()
    }
  end

  def handle_event({:ui_event, :rigs_edit, :click}, model) do
    if model.selected_rig_id do
      rig = Enum.find(model.rigs, &(&1.id == model.selected_rig_id))
      if rig do
        %{model |
          form_mode: :edit,
          form: rig_to_form(rig),
          audio_devices: CoreClient.list_audio_devices()
        }
      else
        model
      end
    else
      model
    end
  end

  def handle_event({:ui_event, :rigs_delete, :click}, model) do
    if model.selected_rig_id do
      case CoreClient.delete_rig(model.selected_rig_id) do
        {:ok, _} ->
          rigs = load_rigs()
          %{model | rigs: rigs, selected_rig_id: first_rig_id(rigs)}
        {:error, _} ->
          model
      end
    else
      model
    end
  end

  def handle_event({:ui_event, :rigs_start, :click}, model) do
    if model.selected_rig_id do
      CoreClient.start_rig(model.selected_rig_id)
      %{model | rigs: load_rigs()}
    else
      model
    end
  end

  def handle_event({:ui_event, :rigs_stop, :click}, model) do
    if model.selected_rig_id do
      CoreClient.stop_rig(model.selected_rig_id)
      %{model | rigs: load_rigs()}
    else
      model
    end
  end

  # Form field changes - update form state reactively
  def handle_event({:ui_event, :form_name, :change, value}, model) do
    put_in(model, [:form, :name], value)
  end

  def handle_event({:ui_event, :form_rig_type, :change, index}, model) do
    rig_type = Enum.at(@rig_types, index) || "test"
    put_in(model, [:form, :rig_type], rig_type)
  end

  def handle_event({:ui_event, :form_protocol, :change, index}, model) do
    protocol = Enum.at(@protocols, index) || "ale_4g"
    put_in(model, [:form, :protocol_stack], protocol)
  end

  def handle_event({:ui_event, :form_self_addr, :change, value}, model) do
    put_in(model, [:form, :self_addr], value)
  end

  def handle_event({:ui_event, :form_control_type, :change, index}, model) do
    control_type = Enum.at(@control_types, index) || "simulator"
    put_in(model, [:form, :control_type], control_type)
  end

  def handle_event({:ui_event, :form_rx_audio, :change, index}, model) do
    names = input_device_names(model.audio_devices)
    rx_audio = Enum.at(names, index) || "(None)"
    put_in(model, [:form, :rx_audio], rx_audio)
  end

  def handle_event({:ui_event, :form_tx_audio, :change, index}, model) do
    names = output_device_names(model.audio_devices)
    tx_audio = Enum.at(names, index) || "(None)"
    put_in(model, [:form, :tx_audio], tx_audio)
  end

  def handle_event({:ui_event, :form_dte_port, :change, value}, model) do
    put_in(model, [:form, :dte_port], value)
  end

  # Simnet field changes
  def handle_event({:ui_event, :form_latitude, :change, value}, model) do
    put_in(model, [:form, :latitude], value)
  end

  def handle_event({:ui_event, :form_longitude, :change, value}, model) do
    put_in(model, [:form, :longitude], value)
  end

  def handle_event({:ui_event, :form_antenna_type, :change, index}, model) do
    antenna = Enum.at(@antenna_types, index) || "dipole"
    put_in(model, [:form, :antenna_type], antenna)
  end

  def handle_event({:ui_event, :form_antenna_height, :change, value}, model) do
    put_in(model, [:form, :antenna_height], value)
  end

  def handle_event({:ui_event, :form_tx_power, :change, value}, model) do
    put_in(model, [:form, :tx_power], value)
  end

  # Rigctld field changes
  def handle_event({:ui_event, :form_rigctld_model, :change, value}, model) do
    put_in(model, [:form, :rigctld_model], value)
  end

  def handle_event({:ui_event, :form_rigctld_device, :change, index}, model) do
    devices = ["" | list_serial_ports()]
    device = Enum.at(devices, index) || ""
    put_in(model, [:form, :rigctld_device], device)
  end

  def handle_event({:ui_event, :form_rigctld_baud, :change, index}, model) do
    baud = Enum.at(baud_rates(), index) || "9600"
    put_in(model, [:form, :rigctld_baud], baud)
  end

  def handle_event({:ui_event, :form_rigctld_civaddr, :change, value}, model) do
    put_in(model, [:form, :rigctld_civaddr], value)
  end

  def handle_event({:ui_event, :form_rigctld_port, :change, value}, model) do
    put_in(model, [:form, :rigctld_port], value)
  end

  # Form buttons
  def handle_event({:ui_event, :form_save, :click}, model) do
    attrs = form_to_attrs(model.form)

    result = case model.form_mode do
      :new -> CoreClient.create_rig(attrs)
      :edit -> CoreClient.update_rig(model.selected_rig_id, attrs)
    end

    case result do
      {:ok, rig} ->
        rigs = load_rigs()
        %{model |
          form_mode: nil,
          rigs: rigs,
          selected_rig_id: rig.id
        }
      {:error, _} ->
        model
    end
  end

  def handle_event({:ui_event, :form_cancel, :click}, model) do
    rigs = load_rigs()
    %{model | form_mode: nil, rigs: rigs}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## Handle Info (for timer-based refresh)
  ## ------------------------------------------------------------------

  def handle_info(:refresh_rigs, model) do
    if model.form_mode == nil do
      rigs = load_rigs()
      selected = if Enum.any?(rigs, &(&1.id == model.selected_rig_id)) do
        model.selected_rig_id
      else
        first_rig_id(rigs)
      end
      {:noreply, %{model | rigs: rigs, selected_rig_id: selected}}
    else
      {:noreply, model}
    end
  end

  def handle_info(_msg, model), do: {:noreply, model}

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    base_intents = [
      {:ensure_panel, :rigs_root, {:page, :rigs}, []}
    ]

    content_intents = if model.form_mode do
      form_view(model)
    else
      list_view(model)
    end

    base_intents ++ content_intents
  end

  ## ------------------------------------------------------------------
  ## List View (default)
  ## ------------------------------------------------------------------

  defp list_view(model) do
    items =
      model.rigs
      |> Enum.map(fn rig ->
        status = if rig_running?(rig.id), do: "[RUN]", else: "[---]"
        addr = if rig.self_addr, do: "0x#{Integer.to_string(rig.self_addr, 16)}", else: "-"
        location = format_location_brief(rig.control_config)
        "#{status} #{rig.name} | #{rig.rig_type || "-"} | #{rig.protocol_stack || "-"} | #{addr}#{location}"
      end)

    selected =
      case Enum.find_index(model.rigs, &(&1.id == model.selected_rig_id)) do
        nil -> 0
        idx -> idx
      end

    [
      # Toolbar
      {:ensure_widget, :rigs_new, :button, :rigs_root, label: "New"},
      {:ensure_widget, :rigs_edit, :button, :rigs_root, label: "Edit"},
      {:ensure_widget, :rigs_delete, :button, :rigs_root, label: "Delete"},
      {:ensure_widget, :rigs_start, :button, :rigs_root, label: "Start"},
      {:ensure_widget, :rigs_stop, :button, :rigs_root, label: "Stop"},
      {:ensure_widget, :rigs_refresh, :button, :rigs_root, label: "Refresh"},
      # List
      {:ensure_widget, :rigs_list, :list_box, :rigs_root, choices: items},
      {:set, :rigs_list, items: items},
      {:set, :rigs_list, selected: selected},
      # Layout
      {:layout, :rigs_root,
       {:vbox, [padding: 5],
        [
          {:hbox, [],
           [
             :rigs_new,
             :rigs_edit,
             :rigs_delete,
             {:spacer, 20},
             :rigs_start,
             :rigs_stop,
             {:spacer, 20},
             :rigs_refresh
           ]},
          {:rigs_list, proportion: 1, flag: :expand}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## Form View (new/edit)
  ## ------------------------------------------------------------------

  defp form_view(model) do
    form = model.form
    input_names = input_device_names(model.audio_devices)
    output_names = output_device_names(model.audio_devices)

    title = if model.form_mode == :new, do: "New Rig", else: "Edit Rig"
    show_simnet = form.rig_type == "test" and form.control_type == "simulator"
    show_rigctld = form.control_type == "rigctld"

    popup_panel = [
      {:ensure_panel, :form_popup, :rigs_root, [border: :simple]}
    ]

    base_widgets = [
      {:ensure_widget, :form_title, :static_text, :form_popup, label: title},

      {:ensure_widget, :form_name_label, :static_text, :form_popup, label: "Name:"},
      {:ensure_widget, :form_name, :text_ctrl, :form_popup, value: form.name},

      {:ensure_widget, :form_rig_type_label, :static_text, :form_popup, label: "Type:"},
      {:ensure_widget, :form_rig_type, :choice, :form_popup, choices: @rig_types},
      {:set, :form_rig_type, selected: Enum.find_index(@rig_types, &(&1 == form.rig_type)) || 0},

      {:ensure_widget, :form_protocol_label, :static_text, :form_popup, label: "Protocol:"},
      {:ensure_widget, :form_protocol, :choice, :form_popup, choices: @protocols},
      {:set, :form_protocol, selected: Enum.find_index(@protocols, &(&1 == form.protocol_stack)) || 0},

      {:ensure_widget, :form_self_addr_label, :static_text, :form_popup, label: "Address (hex):"},
      {:ensure_widget, :form_self_addr, :text_ctrl, :form_popup, value: form.self_addr},

      {:ensure_widget, :form_control_type_label, :static_text, :form_popup, label: "Control:"},
      {:ensure_widget, :form_control_type, :choice, :form_popup, choices: @control_types},
      {:set, :form_control_type, selected: Enum.find_index(@control_types, &(&1 == form.control_type)) || 0},

      {:ensure_widget, :form_rx_audio_label, :static_text, :form_popup, label: "RX Audio:"},
      {:ensure_widget, :form_rx_audio, :choice, :form_popup, choices: input_names},
      {:set, :form_rx_audio, selected: find_device_index(input_names, form.rx_audio)},

      {:ensure_widget, :form_tx_audio_label, :static_text, :form_popup, label: "TX Audio:"},
      {:ensure_widget, :form_tx_audio, :choice, :form_popup, choices: output_names},
      {:set, :form_tx_audio, selected: find_device_index(output_names, form.tx_audio)},

      {:ensure_widget, :form_dte_port_label, :static_text, :form_popup, label: "DTE Port:"},
      {:ensure_widget, :form_dte_port, :text_ctrl, :form_popup, value: form.dte_port},

      {:ensure_widget, :form_save, :button, :form_popup, label: "Save"},
      {:ensure_widget, :form_cancel, :button, :form_popup, label: "Cancel"}
    ]

    simnet_widgets = if show_simnet do
      [
        {:ensure_widget, :form_simnet_header, :static_text, :form_popup, label: "── Simnet Configuration ──"},

        {:ensure_widget, :form_latitude_label, :static_text, :form_popup, label: "Latitude:"},
        {:ensure_widget, :form_latitude, :text_ctrl, :form_popup, value: form.latitude},

        {:ensure_widget, :form_longitude_label, :static_text, :form_popup, label: "Longitude:"},
        {:ensure_widget, :form_longitude, :text_ctrl, :form_popup, value: form.longitude},

        {:ensure_widget, :form_antenna_type_label, :static_text, :form_popup, label: "Antenna:"},
        {:ensure_widget, :form_antenna_type, :choice, :form_popup, choices: @antenna_types},
        {:set, :form_antenna_type, selected: Enum.find_index(@antenna_types, &(&1 == form.antenna_type)) || 0},

        {:ensure_widget, :form_antenna_height_label, :static_text, :form_popup, label: "Height (λ):"},
        {:ensure_widget, :form_antenna_height, :text_ctrl, :form_popup, value: form.antenna_height},

        {:ensure_widget, :form_tx_power_label, :static_text, :form_popup, label: "TX Power (W):"},
        {:ensure_widget, :form_tx_power, :text_ctrl, :form_popup, value: form.tx_power}
      ]
    else
      [
        {:destroy_widget, :form_simnet_header, :static_text},
        {:destroy_widget, :form_latitude_label, :static_text},
        {:destroy_widget, :form_latitude, :text_ctrl},
        {:destroy_widget, :form_longitude_label, :static_text},
        {:destroy_widget, :form_longitude, :text_ctrl},
        {:destroy_widget, :form_antenna_type_label, :static_text},
        {:destroy_widget, :form_antenna_type, :choice},
        {:destroy_widget, :form_antenna_height_label, :static_text},
        {:destroy_widget, :form_antenna_height, :text_ctrl},
        {:destroy_widget, :form_tx_power_label, :static_text},
        {:destroy_widget, :form_tx_power, :text_ctrl}
      ]
    end

    serial_ports = ["(Select...)" | list_serial_ports()]
    device_index = find_serial_port_index(serial_ports, form.rigctld_device)
    baud_index = Enum.find_index(baud_rates(), &(&1 == form.rigctld_baud)) || 2

    rigctld_widgets = if show_rigctld do
      [
        {:ensure_widget, :form_rigctld_header, :static_text, :form_popup, label: "── Rigctld Configuration ──"},

        {:ensure_widget, :form_rigctld_model_label, :static_text, :form_popup, label: "Rig Model #:"},
        {:ensure_widget, :form_rigctld_model, :text_ctrl, :form_popup, value: form.rigctld_model},

        {:ensure_widget, :form_rigctld_device_label, :static_text, :form_popup, label: "Serial Port:"},
        {:ensure_widget, :form_rigctld_device, :choice, :form_popup, choices: serial_ports},
        {:set, :form_rigctld_device, selected: device_index},

        {:ensure_widget, :form_rigctld_baud_label, :static_text, :form_popup, label: "Baud Rate:"},
        {:ensure_widget, :form_rigctld_baud, :choice, :form_popup, choices: baud_rates()},
        {:set, :form_rigctld_baud, selected: baud_index},

        {:ensure_widget, :form_rigctld_civaddr_label, :static_text, :form_popup, label: "CI-V Addr (dec):"},
        {:ensure_widget, :form_rigctld_civaddr, :text_ctrl, :form_popup, value: form.rigctld_civaddr},

        {:ensure_widget, :form_rigctld_port_label, :static_text, :form_popup, label: "TCP Port:"},
        {:ensure_widget, :form_rigctld_port, :text_ctrl, :form_popup, value: form.rigctld_port}
      ]
    else
      [
        {:destroy_widget, :form_rigctld_header, :static_text},
        {:destroy_widget, :form_rigctld_model_label, :static_text},
        {:destroy_widget, :form_rigctld_model, :text_ctrl},
        {:destroy_widget, :form_rigctld_device_label, :static_text},
        {:destroy_widget, :form_rigctld_device, :choice},
        {:destroy_widget, :form_rigctld_baud_label, :static_text},
        {:destroy_widget, :form_rigctld_baud, :choice},
        {:destroy_widget, :form_rigctld_civaddr_label, :static_text},
        {:destroy_widget, :form_rigctld_civaddr, :text_ctrl},
        {:destroy_widget, :form_rigctld_port_label, :static_text},
        {:destroy_widget, :form_rigctld_port, :text_ctrl}
      ]
    end

    form_inner_layout = form_layout(show_simnet, show_rigctld)

    outer_layout = {:layout, :rigs_root,
     {:vbox, [],
      [
        {:spacer, 30},
        {:form_popup, proportion: 0, flag: [:align_center_horizontal]},
        {:spacer, 30}
      ]}}

    popup_panel ++ base_widgets ++ simnet_widgets ++ rigctld_widgets ++ [form_inner_layout, outer_layout]
  end

  defp form_layout(show_simnet, show_rigctld) do
    base_rows = [
      {:hbox, [], [:form_name_label, :form_name]},
      {:hbox, [], [:form_rig_type_label, :form_rig_type]},
      {:hbox, [], [:form_protocol_label, :form_protocol]},
      {:hbox, [], [:form_self_addr_label, :form_self_addr]},
      {:hbox, [], [:form_control_type_label, :form_control_type]},
      {:hbox, [], [:form_rx_audio_label, :form_rx_audio]},
      {:hbox, [], [:form_tx_audio_label, :form_tx_audio]},
      {:hbox, [], [:form_dte_port_label, :form_dte_port]}
    ]

    simnet_rows = if show_simnet do
      [
        {:hbox, [], [:form_simnet_header]},
        {:hbox, [], [:form_latitude_label, :form_latitude]},
        {:hbox, [], [:form_longitude_label, :form_longitude]},
        {:hbox, [], [:form_antenna_type_label, :form_antenna_type]},
        {:hbox, [], [:form_antenna_height_label, :form_antenna_height]},
        {:hbox, [], [:form_tx_power_label, :form_tx_power]}
      ]
    else
      []
    end

    rigctld_rows = if show_rigctld do
      [
        {:hbox, [], [:form_rigctld_header]},
        {:hbox, [], [:form_rigctld_model_label, :form_rigctld_model]},
        {:hbox, [], [:form_rigctld_device_label, :form_rigctld_device]},
        {:hbox, [], [:form_rigctld_baud_label, :form_rigctld_baud]},
        {:hbox, [], [:form_rigctld_civaddr_label, :form_rigctld_civaddr]},
        {:hbox, [], [:form_rigctld_port_label, :form_rigctld_port]}
      ]
    else
      []
    end

    button_row = {:hbox, [], [:form_save, :form_cancel]}

    all_rows = [{:hbox, [], [:form_title]}] ++ base_rows ++ simnet_rows ++ rigctld_rows ++ [button_row]

    {:layout, :form_popup, {:vbox, [padding: 15], all_rows}}
  end

  ## ------------------------------------------------------------------
  ## Form <-> Data Conversion
  ## ------------------------------------------------------------------

  defp rig_to_form(rig) do
    config = rig.control_config || %{}
    {lat, lon} = get_location(config)
    antenna = config["antenna"] || %{}

    %{
      name: rig.name || "",
      rig_type: rig.rig_type || "test",
      protocol_stack: rig.protocol_stack || "ale_4g",
      self_addr: format_hex(rig.self_addr),
      control_type: rig.control_type || "simulator",
      rx_audio: rig.rx_audio || "(None)",
      tx_audio: rig.tx_audio || "(None)",
      dte_port: to_string(config["dte_port"] || 3000),
      # Simnet
      latitude: format_float(lat, "64.8378"),
      longitude: format_float(lon, "-147.7164"),
      antenna_type: antenna["type"] || "dipole",
      antenna_height: format_float(antenna["height_wavelengths"], "0.5"),
      tx_power: format_float(config["tx_power_watts"], "100"),
      # Rigctld
      rigctld_model: to_string(config["model"] || 1),
      rigctld_device: config["device"] || "",
      rigctld_baud: to_string(config["baud"] || 9600),
      rigctld_civaddr: format_civaddr(config["civaddr"]),
      rigctld_port: to_string(config["port"] || 4532)
    }
  end

  defp form_to_attrs(form) do
    dte_port = parse_int(form.dte_port) || 3000

    base = %{
      name: form.name,
      rig_type: form.rig_type,
      protocol_stack: form.protocol_stack,
      self_addr: parse_hex(form.self_addr),
      control_type: form.control_type,
      rx_audio: null_if_none(form.rx_audio),
      tx_audio: null_if_none(form.tx_audio),
      enabled: true
    }

    # Build control_config with DTE port and backend-specific config
    config = %{"dte_port" => dte_port}

    config = cond do
      form.rig_type == "test" and form.control_type == "simulator" ->
        Map.merge(config, build_simnet_config(form))

      form.control_type == "rigctld" ->
        Map.merge(config, build_rigctld_config(form))

      true ->
        config
    end

    Map.put(base, :control_config, config)
  end

  defp build_rigctld_config(form) do
    config = %{
      "model" => parse_int(form.rigctld_model) || 1,
      "device" => form.rigctld_device,
      "baud" => parse_int(form.rigctld_baud) || 9600,
      "port" => parse_int(form.rigctld_port) || 4532
    }

    # Only include civaddr if provided (it's optional, depends on rig)
    civaddr = parse_int(form.rigctld_civaddr)
    if civaddr do
      Map.put(config, "civaddr", civaddr)
    else
      config
    end
  end

  defp build_simnet_config(form) do
    lat = parse_float(form.latitude)
    lon = parse_float(form.longitude)
    height = parse_float(form.antenna_height) || 0.5
    power = parse_float(form.tx_power) || 100

    config = %{
      "antenna" => %{
        "type" => form.antenna_type,
        "height_wavelengths" => height
      },
      "tx_power_watts" => power,
      "noise_floor_dbm" => -100.0
    }

    if lat && lon do
      Map.put(config, "location", [lat, lon])
    else
      config
    end
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp load_rigs do
    case CoreClient.list_rigs() do
      {:error, _} -> []
      rigs when is_list(rigs) -> rigs
      _ -> []
    end
  end

  defp rig_running?(rig_id) do
    CoreClient.rig_running?(rig_id)
  end

  defp first_rig_id([]), do: nil
  defp first_rig_id([rig | _]), do: rig.id

  defp input_devices(devices) do
    Enum.filter(devices, &(&1.direction in [:input, :duplex]))
  end

  defp output_devices(devices) do
    Enum.filter(devices, &(&1.direction in [:output, :duplex]))
  end

  defp input_device_names(devices) do
    ["(None)" | Enum.map(input_devices(devices), & &1.name)]
  end

  defp output_device_names(devices) do
    ["(None)" | Enum.map(output_devices(devices), & &1.name)]
  end

  defp find_device_index(_names, nil), do: 0
  defp find_device_index(names, device_name) do
    case Enum.find_index(names, &(&1 == device_name)) do
      nil -> 0
      idx -> idx
    end
  end

  defp null_if_none("(None)"), do: nil
  defp null_if_none(value), do: value

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

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
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

  defp format_hex(nil), do: ""
  defp format_hex(val) when is_integer(val), do: Integer.to_string(val, 16)
  defp format_hex(_), do: ""

  defp format_float(nil, default), do: default
  defp format_float(val, _default) when is_number(val), do: to_string(val)
  defp format_float(_, default), do: default

  defp get_location(config) do
    case config["location"] do
      [lat, lon] when is_number(lat) and is_number(lon) -> {lat, lon}
      _ -> {nil, nil}
    end
  end

  defp format_location_brief(nil), do: ""
  defp format_location_brief(config) do
    case get_location(config) do
      {nil, nil} -> ""
      {lat, lon} -> " | #{Float.round(lat, 2)},#{Float.round(lon, 2)}"
    end
  end

  # --- Rigctld Helpers ---

  defp list_serial_ports do
    case :os.type() do
      {:unix, :darwin} -> list_macos_serial_ports()
      {:unix, _linux} -> list_linux_serial_ports()
      _ -> []
    end
  end

  defp list_macos_serial_ports do
    # cu.* is preferred for outgoing connections on macOS
    (Path.wildcard("/dev/cu.usbserial*") ++
     Path.wildcard("/dev/cu.SLAB*") ++
     Path.wildcard("/dev/cu.wchusbserial*") ++
     Path.wildcard("/dev/cu.usbmodem*"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_linux_serial_ports do
    (Path.wildcard("/dev/ttyUSB*") ++
     Path.wildcard("/dev/ttyACM*"))
    |> Enum.sort()
  end

  defp baud_rates do
    ["1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200"]
  end

  defp find_serial_port_index(ports, "") do
    0
  end

  defp find_serial_port_index(ports, device) do
    case Enum.find_index(ports, &(&1 == device)) do
      nil -> 0
      idx -> idx
    end
  end

  defp format_civaddr(nil), do: ""
  defp format_civaddr(val) when is_integer(val), do: to_string(val)
  defp format_civaddr(_), do: ""
end
