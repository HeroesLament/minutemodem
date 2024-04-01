defmodule MinuteModemCore.Rig.Types.VHF do
  @moduledoc """
  VHF/UHF Transceiver rig type.

  For VHF (30-300 MHz) and UHF (300 MHz - 3 GHz) radios.
  Primary use cases:
  - AX.25 Packet radio
  - APRS
  - Future: M17, FreeDV on VHF, etc.

  Audio config differs from HF:
  - Often 48kHz sample rate for wider deviation FM
  - May need different filtering
  """

  @behaviour MinuteModemCore.Rig.Types.Behaviour

  @impl true
  def type_id, do: :vhf

  @impl true
  def display_name, do: "VHF/UHF Transceiver"

  @impl true
  def description, do: "VHF/UHF radio (30 MHz - 3 GHz)"

  @impl true
  def supported_control_backends, do: [:rigctld, :flrig]

  @impl true
  def supported_protocols do
    [:packet, :aprs, :m17, :freedv]
  end

  @impl true
  def audio_config do
    %{
      # 48kHz for FM deviation headroom
      sample_rate: 48000,
      channels: 1,
      format: :s16le
    }
  end

  @impl true
  def frequency_range do
    # 30 MHz to 3 GHz (covers 2m, 70cm, etc.)
    {30_000_000, 3_000_000_000}
  end

  @impl true
  def can_transmit?, do: true

  @impl true
  def faceplate_config do
    %{
      show_frequency: true,
      show_mode: true,
      show_ptt: true,
      show_s_meter: true,
      show_power: true,
      show_play_button: false,
      custom_controls: [
        %{
          type: :dropdown,
          id: :ctcss_tone,
          label: "CTCSS",
          source: :ctcss_tones
        },
        %{
          type: :dropdown,
          id: :packet_path,
          label: "Packet Path",
          source: :digipeater_paths
        },
        %{
          type: :indicator,
          id: :dcd,
          label: "DCD",
          states: [:off, :on]
        }
      ]
    }
  end

  @impl true
  def default_control_config do
    %{
      "backend" => "rigctld",
      "model" => 1,
      "device" => "/dev/ttyUSB0",
      "baud" => 9600,
      "port" => 4534
    }
  end

  @impl true
  def validate_control_config(config) do
    # Same validation as HF for now
    MinuteModemCore.Rig.Types.HF.validate_control_config(config)
  end
end
