defmodule MinuteModemCore.Rig.Types.HF_RX do
  @moduledoc """
  HF Receive-Only rig type.

  For diversity receivers, monitoring stations, or SDR receivers.
  Use cases:
  - Diversity reception (multiple antennas/receivers)
  - ALE monitoring / scanning
  - Spectrum monitoring
  - SDR-based receivers (RTL-SDR, KiwiSDR, etc.)

  No transmit capability - PTT controls are hidden.
  """

  @behaviour MinuteModemCore.Rig.Types.Behaviour

  @impl true
  def type_id, do: :hf_rx

  @impl true
  def display_name, do: "HF Receiver"

  @impl true
  def description, do: "HF receive-only (monitoring, diversity)"

  @impl true
  def supported_control_backends, do: [:rigctld, :flrig, :simulator]

  @impl true
  def supported_protocols do
    # RX-only, so no TX-dependent protocols
    # Can still decode ALE, just can't respond
    [:ale_2g, :ale_3g, :ale_4g, :stanag_5066, :mil_188_110]
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
  def frequency_range do
    {1_600_000, 30_000_000}
  end

  @impl true
  def can_transmit?, do: false

  @impl true
  def faceplate_config do
    %{
      show_frequency: true,
      show_mode: true,
      show_ptt: false,
      show_s_meter: true,
      show_power: false,
      show_play_button: false,
      custom_controls: [
        %{
          type: :indicator,
          id: :signal_quality,
          label: "Signal",
          states: [:none, :weak, :fair, :good, :excellent]
        },
        %{
          type: :dropdown,
          id: :scan_list,
          label: "Scan List",
          source: :frequency_lists
        },
        %{
          type: :toggle,
          id: :scanning,
          label: "Scan"
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
      "port" => 4533
    }
  end

  @impl true
  def validate_control_config(config) do
    backend = config["backend"]

    cond do
      backend == "simulator" ->
        :ok

      backend in ["rigctld", "flrig"] ->
        # Same validation as HF
        MinuteModemCore.Rig.Types.HF.validate_control_config(config)

      true ->
        {:error, {:unsupported_backend, backend}}
    end
  end
end
