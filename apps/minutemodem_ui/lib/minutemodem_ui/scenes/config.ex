defmodule MinuteModemUI.Scenes.Config do
  @moduledoc """
  Config panel scene.
  """

  use WxMVU.Scene

  alias MinuteModemUI.CoreClient

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    devices = CoreClient.list_audio_devices()

    input_default = find_default_device(devices, :input)
    output_default = find_default_device(devices, :output)

    %{
      audio_devices: devices,
      selected_input_name: input_default,
      selected_output_name: output_default,
      codeplug_path: nil
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :config_input_device, :change, index}, model) do
    device = input_devices(model.audio_devices) |> Enum.at(index)
    %{model | selected_input_name: device && device.name}
  end

  def handle_event({:ui_event, :config_output_device, :change, index}, model) do
    device = output_devices(model.audio_devices) |> Enum.at(index)
    %{model | selected_output_name: device && device.name}
  end

  def handle_event({:ui_event, :config_refresh_devices, :click}, model) do
    devices = CoreClient.list_audio_devices()
    %{model | audio_devices: devices}
  end

  def handle_event({:ui_event, :config_codeplug_picker, :change, path}, model) do
    %{model | codeplug_path: path}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    input_devs = input_devices(model.audio_devices)
    output_devs = output_devices(model.audio_devices)

    input_names = Enum.map(input_devs, & &1.name)
    output_names = Enum.map(output_devs, & &1.name)

    input_index = find_index_by_name(input_devs, model.selected_input_name)
    output_index = find_index_by_name(output_devs, model.selected_output_name)

    [
      {:ensure_panel, :config_root, {:page, :config}, []},

      {:ensure_widget, :config_audio_box, :static_box, :config_root,
       label: "Operator Audio Devices"},

      {:ensure_widget, :config_input_device, :choice, :config_audio_box,
       choices: input_names},

      {:ensure_widget, :config_output_device, :choice, :config_audio_box,
       choices: output_names},

      {:ensure_widget, :config_refresh_devices, :button, :config_audio_box,
       label: "Refresh Devices"},

      {:set, :config_input_device, items: input_names},
      {:set, :config_output_device, items: output_names},
      {:set, :config_input_device, selected: input_index},
      {:set, :config_output_device, selected: output_index},

      {:layout, :config_audio_box,
       {:vbox, [],
        [
          :config_input_device,
          :config_output_device,
          {:config_refresh_devices, align: :center}
        ]}},

      {:ensure_widget, :config_codeplug_box, :static_box, :config_root,
       label: "Import Codeplug"},

      {:ensure_widget, :config_codeplug_picker, :file_picker, :config_codeplug_box,
       message: "Select codeplug file",
       wildcard: "Codeplug files (*.csv;*.json)|*.csv;*.json|All files (*.*)|*.*",
       must_exist: true,
       use_textctrl: true},

      {:layout, :config_codeplug_box,
       {:vbox, [], [:config_codeplug_picker]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp input_devices(devices) do
    Enum.filter(devices, &(&1.direction in [:input, :duplex]))
  end

  defp output_devices(devices) do
    Enum.filter(devices, &(&1.direction in [:output, :duplex]))
  end

  defp find_default_device(devices, :input) do
    device =
      Enum.find(devices, fn d ->
        d.direction in [:input, :duplex] and d.default_device
      end)

    device && device.name
  end

  defp find_default_device(devices, :output) do
    device =
      Enum.find(devices, fn d ->
        d.direction in [:output, :duplex] and d.default_device
      end)

    device && device.name
  end

  defp find_index_by_name(devices, name) do
    Enum.find_index(devices, &(&1.name == name))
  end
end
