defmodule MinuteModemCore.ALE.Frame do
  @moduledoc """
  MIL-STD-188-141D 4G ALE Frame Assembly.

  Provides high-level frame building functions that use the proper
  WALE waveforms (Deep or Fast) per the specification.

  ## Frame Types

  - **Deep WALE** - Robust waveform for challenging HF channels
    - 240ms preamble
    - Walsh-16 data modulation (~150 bps)

  - **Fast WALE** - Quick waveform for benign channels
    - 120ms preamble
    - BPSK data modulation (~2400 bps)

  ## Usage

      # Build an LSU Request frame
      symbols = Frame.build_lsu_request_frame(my_addr, dest_addr,
        waveform: :deep,
        tuner_time_ms: 40
      )

      # Modulate to audio
      samples = Modem8PSK.modulate(mod, symbols)
  """

  alias MinuteModemCore.ALE.{PDU, Waveform}

  # Default waveform configuration
  @default_waveform :deep
  @default_tuner_time_ms 0
  @default_capture_probe_count 1
  @default_preamble_count 1

  # Symbol rate
  @symbol_rate 2400

  # ===========================================================================
  # LSU Request Frame
  # ===========================================================================

  @doc """
  Build a Link Setup Request frame.

  This is the standard frame for initiating an ALE call.

  ## Options
  - `:waveform` - `:deep` or `:fast` (default: `:deep`)
  - `:tuner_time_ms` - Radio tuning time in ms (default: 0)
  - `:capture_probe_count` - Number of capture probes (default: 1)
  - `:preamble_count` - Preamble repetitions, Deep only (default: 1)
  - `:voice` - Voice capability flag (default: false)
  - `:traffic_type` - Traffic type code (default: 0)
  - `:assigned_subchannels` - Subchannel assignment (default: 0xFFFF)
  - `:occupied_subchannels` - Occupied subchannels (default: 0)
  """
  def build_lsu_request_frame(caller_addr, called_addr, opts \\ []) do
    pdu = %PDU.LsuReq{
      caller_addr: caller_addr,
      called_addr: called_addr,
      voice: Keyword.get(opts, :voice, false),
      traffic_type: Keyword.get(opts, :traffic_type, 0),
      assigned_subchannels: Keyword.get(opts, :assigned_subchannels, 0xFFFF),
      occupied_subchannels: Keyword.get(opts, :occupied_subchannels, 0)
    }

    pdu_binary = PDU.encode(pdu)

    waveform_opts = [
      waveform: Keyword.get(opts, :waveform, @default_waveform),
      async: true,  # LSU_Req is always async (scanning call)
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, @default_tuner_time_ms),
      capture_probe_count: Keyword.get(opts, :capture_probe_count, @default_capture_probe_count),
      preamble_count: Keyword.get(opts, :preamble_count, @default_preamble_count),
      more_pdus: false
    ]

    Waveform.assemble_frame(pdu_binary, waveform_opts)
  end

  # ===========================================================================
  # LSU Confirm Frame
  # ===========================================================================

  @doc """
  Build a Link Setup Confirmation frame.

  Sent by the called station to confirm link establishment.
  """
  def build_lsu_confirm_frame(caller_addr, called_addr, opts \\ []) do
    pdu = %PDU.LsuConf{
      caller_addr: caller_addr,
      called_addr: called_addr,
      voice: Keyword.get(opts, :voice, false),
      snr: Keyword.get(opts, :snr, 0),
      tx_subchannels: Keyword.get(opts, :tx_subchannels, 0xFFFF),
      rx_subchannels: Keyword.get(opts, :rx_subchannels, 0xFFFF)
    }

    pdu_binary = PDU.encode(pdu)

    # Confirm is typically sync (responding to known caller)
    # but can be async if caller moved channels
    waveform_opts = [
      waveform: Keyword.get(opts, :waveform, @default_waveform),
      async: Keyword.get(opts, :async, true),
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, @default_tuner_time_ms),
      capture_probe_count: Keyword.get(opts, :capture_probe_count, @default_capture_probe_count),
      preamble_count: Keyword.get(opts, :preamble_count, @default_preamble_count),
      more_pdus: false
    ]

    Waveform.assemble_frame(pdu_binary, waveform_opts)
  end

  # ===========================================================================
  # LSU Terminate Frame
  # ===========================================================================

  @doc """
  Build a Link Termination frame.
  """
  def build_lsu_term_frame(caller_addr, called_addr, reason, opts \\ []) do
    pdu = %PDU.LsuTerm{
      caller_addr: caller_addr,
      called_addr: called_addr,
      reason: reason
    }

    pdu_binary = PDU.encode(pdu)

    waveform_opts = [
      waveform: Keyword.get(opts, :waveform, @default_waveform),
      async: Keyword.get(opts, :async, true),
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, @default_tuner_time_ms),
      capture_probe_count: Keyword.get(opts, :capture_probe_count, @default_capture_probe_count),
      preamble_count: Keyword.get(opts, :preamble_count, @default_preamble_count),
      more_pdus: false
    ]

    Waveform.assemble_frame(pdu_binary, waveform_opts)
  end

  # ===========================================================================
  # Text Message Frame
  # ===========================================================================

  @doc """
  Build a text message (AMD) frame.
  """
  def build_text_message_frame(text, opts \\ []) do
    pdu = %PDU.TxtMessage{
      control: Keyword.get(opts, :control, 0),
      countdown: Keyword.get(opts, :countdown, 0),
      text: text
    }

    pdu_binary = PDU.encode(pdu)

    waveform_opts = [
      waveform: Keyword.get(opts, :waveform, @default_waveform),
      async: Keyword.get(opts, :async, false),  # Messages typically sync
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, @default_tuner_time_ms),
      capture_probe_count: Keyword.get(opts, :capture_probe_count, @default_capture_probe_count),
      preamble_count: Keyword.get(opts, :preamble_count, @default_preamble_count),
      more_pdus: Keyword.get(opts, :more_pdus, false)
    ]

    Waveform.assemble_frame(pdu_binary, waveform_opts)
  end

  # ===========================================================================
  # Generic Frame Assembly
  # ===========================================================================

  @doc """
  Assemble a frame from a raw PDU struct.
  """
  def assemble_frame(pdu, opts \\ []) do
    pdu_binary = PDU.encode(pdu)

    waveform_opts = [
      waveform: Keyword.get(opts, :waveform, @default_waveform),
      async: Keyword.get(opts, :async, true),
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, @default_tuner_time_ms),
      capture_probe_count: Keyword.get(opts, :capture_probe_count, @default_capture_probe_count),
      preamble_count: Keyword.get(opts, :preamble_count, @default_preamble_count),
      more_pdus: Keyword.get(opts, :more_pdus, false)
    ]

    Waveform.assemble_frame(pdu_binary, waveform_opts)
  end

  # ===========================================================================
  # Timing
  # ===========================================================================

  @doc """
  Calculate frame duration in milliseconds.
  """
  def frame_duration_ms(symbols) when is_list(symbols) do
    length(symbols) * 1000 / @symbol_rate
  end

  @doc """
  Calculate number of audio samples for a frame.
  """
  def frame_samples(symbols, sample_rate \\ 9600) when is_list(symbols) do
    duration_s = length(symbols) / @symbol_rate
    round(duration_s * sample_rate)
  end

  @doc """
  Get detailed timing breakdown for a frame configuration.
  """
  def frame_timing(pdu_binary, opts \\ []) do
    Waveform.frame_timing(pdu_binary, opts)
  end

  # ===========================================================================
  # Constants
  # ===========================================================================

  @doc """
  Symbol rate.
  """
  def symbol_rate, do: @symbol_rate

  @doc """
  Default waveform.
  """
  def default_waveform, do: @default_waveform
end
