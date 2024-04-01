defmodule MinuteModemCore.Rig.Types.Test do
  @moduledoc """
  Test/Simulator rig type.

  For development and testing without real hardware.
  Features:
  - No physical radio control
  - Can inject audio from files
  - Useful for testing ALE decode, protocol stacks
  """

  @behaviour MinuteModemCore.Rig.Types.Behaviour

  @impl true
  def type_id, do: :test

  @impl true
  def display_name, do: "Test / Simulator"

  @impl true
  def description, do: "Virtual rig for testing without hardware"

  @impl true
  def supported_control_backends, do: [:simulator]

  @impl true
  def supported_protocols do
    # Test rig can run any protocol for testing purposes
    [:ale_2g, :ale_3g, :ale_4g, :stanag_5066, :mil_188_110, :packet, :aprs]
  end

  @impl true
  def audio_config do
    %{
      sample_rate: 8000,
      channels: 1,
      format: :s16le
    }
  end

  @impl true
  def frequency_range, do: :any

  @impl true
  def can_transmit?, do: false

  @impl true
  def faceplate_config do
    %{
      show_frequency: false,
      show_mode: false,
      show_ptt: false,
      show_s_meter: false,
      show_power: false,
      show_play_button: true,
      custom_controls: [
        %{
          type: :file_picker,
          id: :rx_audio_file,
          label: "RX Audio File",
          filter: "*.wav;*.raw"
        },
        %{
          type: :checkbox,
          id: :loop_playback,
          label: "Loop"
        },
        %{
          type: :progress_bar,
          id: :playback_progress,
          label: "Playback"
        }
      ]
    }
  end

  @impl true
  def default_control_config do
    %{
      "backend" => "simulator"
    }
  end

  @impl true
  def validate_control_config(_config), do: :ok
end
