defmodule MinuteModemCore.Rig.Types.HF do
  @moduledoc """
  HF Transceiver rig type.

  For HF radios (1.6 - 30 MHz).
  Primary use cases:
  - ALE (2G, 3G, 4G)
  - MIL-STD-188-110 data modes
  - STANAG 5066
  - Voice

  Audio config:
  - 8kHz or 9600Hz sample rate for narrowband HF
  - Single channel
  """

  @behaviour MinuteModemCore.Rig.Types.Behaviour

  @impl true
  def type_id, do: :hf

  @impl true
  def display_name, do: "HF Transceiver"

  @impl true
  def description, do: "HF radio (1.6 - 30 MHz)"

  @impl true
  def supported_control_backends, do: [:rigctld, :flrig]

  @impl true
  def supported_protocols do
    [:ale_2g, :ale_3g, :ale_4g, :stanag_5066, :mil_188_110]
  end

  @impl true
  def audio_config do
    %{
      sample_rate: 9600,
      channels: 1,
      format: :s16le
    }
  end

  @impl true
  def frequency_range do
    # 1.6 MHz to 30 MHz
    {1_600_000, 30_000_000}
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
          type: :indicator,
          id: :ale_state,
          label: "ALE",
          states: [:idle, :scanning, :linking, :linked]
        },
        %{
          type: :indicator,
          id: :data_state,
          label: "Data",
          states: [:idle, :rx, :tx]
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
      "port" => 4532
    }
  end

  @impl true
  def validate_control_config(config) do
    cond do
      not is_map(config) ->
        {:error, :invalid_config}

      Map.get(config, "backend") == "rigctld" and not Map.has_key?(config, "device") ->
        {:error, :missing_device}

      true ->
        :ok
    end
  end
end
