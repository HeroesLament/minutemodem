defmodule MinuteModemCore.ALE.WaveGen do
  @moduledoc """
  Generate WALE waveforms and save as WAV files.

  Usage:
    MinuteModemCore.ALE.WaveGen.save_lsu_req(:deep, "/tmp/deep_wale_lsu_req.wav")
    MinuteModemCore.ALE.WaveGen.save_lsu_req(:fast, "/tmp/fast_wale_lsu_req.wav")
  """

  alias MinuteModemCore.ALE.{PDU, Waveform}
  alias MinuteModemCore.DSP.PhyModem

  @sample_rate 9600

  @doc """
  Generate and save an LSU_Req frame as a WAV file.
  """
  def save_lsu_req(waveform, path, opts \\ []) do
    caller = Keyword.get(opts, :caller, 0x1234)
    called = Keyword.get(opts, :called, 0x5678)
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 40)

    pdu = %PDU.LsuReq{
      caller_addr: caller,
      called_addr: called,
      voice: Keyword.get(opts, :voice, false),
      more: false,
      equipment_class: 1,
      traffic_type: 0,
      assigned_subchannels: 0xFFFF,
      occupied_subchannels: 0
    }

    save_pdu(pdu, waveform, path, tuner_time_ms: tuner_time_ms)
  end

  @doc """
  Generate and save an LSU_Conf frame as a WAV file.
  """
  def save_lsu_conf(waveform, path, opts \\ []) do
    caller = Keyword.get(opts, :caller, 0x1234)
    called = Keyword.get(opts, :called, 0x5678)

    pdu = %PDU.LsuConf{
      caller_addr: caller,
      called_addr: called,
      voice: false,
      snr: 10,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }

    save_pdu(pdu, waveform, path, [])
  end

  @doc """
  Generate and save an LSU_Term frame as a WAV file.
  """
  def save_lsu_term(waveform, path, opts \\ []) do
    caller = Keyword.get(opts, :caller, 0x1234)
    called = Keyword.get(opts, :called, 0x5678)
    reason = Keyword.get(opts, :reason, 0)

    pdu = %PDU.LsuTerm{
      caller_addr: caller,
      called_addr: called,
      reason: reason
    }

    save_pdu(pdu, waveform, path, [])
  end

  @doc """
  Generate and save any PDU as a WAV file.
  """
  def save_pdu(pdu, waveform, path, opts \\ []) do
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)

    # Encode PDU
    pdu_binary = PDU.encode(pdu)

    # Assemble WALE frame
    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      async: true,
      tuner_time_ms: tuner_time_ms,
      capture_probe_count: 1,
      preamble_count: 1
    )

    # Get timing info
    timing = Waveform.frame_timing(pdu_binary,
      waveform: waveform,
      async: true,
      tuner_time_ms: tuner_time_ms
    )

    IO.puts("Generating #{waveform} WALE frame:")
    IO.puts("  PDU: #{pdu.__struct__ |> Module.split() |> List.last()}")
    IO.puts("  Symbols: #{length(symbols)}")
    IO.puts("  Duration: #{Float.round(timing.duration_ms, 1)}ms")

    # Modulate to audio
    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    all_samples = samples ++ flush

    IO.puts("  Samples: #{length(all_samples)} @ #{@sample_rate}Hz")

    # Save as WAV
    write_wav(path, all_samples, @sample_rate)

    IO.puts("  Saved: #{path}")
    {:ok, path}
  end

  @doc """
  Generate raw symbols (no audio) and return them.
  """
  def generate_symbols(pdu, waveform, opts \\ []) do
    tuner_time_ms = Keyword.get(opts, :tuner_time_ms, 0)
    pdu_binary = PDU.encode(pdu)

    Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      async: true,
      tuner_time_ms: tuner_time_ms,
      capture_probe_count: 1,
      preamble_count: 1
    )
  end

  @doc """
  Generate audio samples (no file) and return them.
  """
  def generate_audio(pdu, waveform, opts \\ []) do
    symbols = generate_symbols(pdu, waveform, opts)

    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)
    samples = PhyModem.unified_mod_modulate(mod, symbols)
    flush = PhyModem.unified_mod_flush(mod)
    samples ++ flush
  end

  # Write 16-bit mono WAV file
  defp write_wav(path, samples, sample_rate) do
    # Convert samples to binary (s16le)
    pcm_data =
      samples
      |> Enum.map(fn s ->
        # Clamp to i16 range
        clamped = max(-32768, min(32767, round(s)))
        <<clamped::little-signed-16>>
      end)
      |> IO.iodata_to_binary()

    # WAV header
    data_size = byte_size(pcm_data)
    byte_rate = sample_rate * 2  # 16-bit mono

    header = <<
      "RIFF",
      (data_size + 36)::little-32,
      "WAVE",
      "fmt ",
      16::little-32,          # fmt chunk size
      1::little-16,           # PCM format
      1::little-16,           # mono
      sample_rate::little-32, # sample rate
      byte_rate::little-32,   # byte rate
      2::little-16,           # block align
      16::little-16,          # bits per sample
      "data",
      data_size::little-32
    >>

    File.write!(path, header <> pcm_data)
  end
end
