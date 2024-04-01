defmodule ALE110DFileTest do
  alias MinuteModemCore.DSP.PhyModem
  alias MinuteModemCore.Modem110D.{Preamble, Rx, MiniProbe, Codec, WID}

  @sample_rate 9600
  @wav_path "/tmp/hello_world_110d.wav"

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("110D FILE-BASED TX/RX TEST (~6 second transmission)")
    IO.puts(String.duplicate("=", 60))

    # Generate 5KB of random binary data for ~6 second TX at QAM16 rates
    # QAM16 @ 2400 baud = 9600 bps raw, ~7200 bps with 3/4 FEC
    :rand.seed(:exsss, {2025, 12, 20})
    message = :crypto.strong_rand_bytes(5400)

    IO.puts("\n--- TX Phase ---\n")
    {:ok, tx_bits} = transmit_to_file(message)
    IO.puts("Saved: #{@wav_path}")

    IO.puts("\n--- RX Phase ---\n")
    {:ok, rx_message} = receive_from_file()

    IO.puts("\nTX: #{byte_size(message)} bytes (#{length(tx_bits)} bits)")
    IO.puts("RX: #{byte_size(rx_message)} bytes")

    if rx_message == message do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("✓ SUCCESS! File-based 110D test passed!")
      IO.puts("  Transferred #{byte_size(message)} bytes with 100% accuracy")
      IO.puts(String.duplicate("=", 60) <> "\n")
      :ok
    else
      # Count byte errors
      tx_bytes = :binary.bin_to_list(message)
      rx_bytes = :binary.bin_to_list(rx_message)
      errors = Enum.zip(tx_bytes, rx_bytes) |> Enum.count(fn {a, b} -> a != b end)
      IO.puts("\n✗ FAILED: #{errors} byte errors out of #{byte_size(message)}")
      {:error, :mismatch}
    end
  end

  defp transmit_to_file(message) when is_binary(message) do
    message_bits = for <<byte <- message>>, i <- 7..0//-1, do: Bitwise.band(Bitwise.bsr(byte, i), 1)

    IO.puts("Message: #{byte_size(message)} bytes (#{length(message_bits)} bits)")

    wid = WID.new(7, :short, 7)
    probe = MiniProbe.generate_for_waveform(7, 3)

    {:ok, tx_symbols} = Codec.encode(message_bits, wid, use_eom: true)
    IO.puts("Encoded: #{length(tx_symbols)} symbols")

    preamble = Preamble.build(3, 7, :short, 7, m: 2, tlc_blocks: 2)

    mod = PhyModem.unified_mod_new(:psk8, @sample_rate)

    preamble_audio = PhyModem.unified_mod_modulate(mod, preamble)

    probe_tagged = Enum.map(probe, fn s -> {s, :psk8} end)
    initial_probe_audio = PhyModem.unified_mod_modulate_mixed(mod, probe_tagged)

    data_audio = tx_symbols |> Enum.chunk_every(256) |> Enum.flat_map(fn block ->
      data_tagged = Enum.map(block, fn s -> {s, :qam16} end)
      probe_tagged = Enum.map(probe, fn s -> {s, :psk8} end)
      PhyModem.unified_mod_modulate_mixed(mod, data_tagged ++ probe_tagged)
    end)

    tail = PhyModem.unified_mod_flush(mod)
    audio = preamble_audio ++ initial_probe_audio ++ data_audio ++ tail

    duration_ms = length(audio) / @sample_rate * 1000
    IO.puts("Audio: #{length(audio)} samples (#{Float.round(duration_ms, 1)}ms)")

    write_wav(@wav_path, audio, @sample_rate)

    {:ok, message_bits}
  end

  defp receive_from_file do
    IO.puts("Loading: #{@wav_path}")

    samples = read_wav(@wav_path)
    IO.puts("Read: #{length(samples)} samples")

    wid = WID.new(7, :short, 7)

    demod = PhyModem.unified_demod_new(:psk8, @sample_rate)
    {iq, _} = PhyModem.demod_iq(demod, samples)
    IO.puts("Demodulated: #{length(iq)} I/Q samples")

    rx = Rx.new(3) |> Rx.start() |> elem(0)
    {rx, events} = Rx.process(rx, iq)
    {_rx, flush_events} = Rx.flush(rx)
    all_events = events ++ flush_events

    rx_symbols = Enum.flat_map(
      Enum.filter(all_events, fn {:data, _} -> true; _ -> false end),
      fn {:data, syms} -> syms end
    )
    IO.puts("Received: #{length(rx_symbols)} symbols")

    {:ok, decoder} = Codec.decoder_new(wid)
    {decoder, _} = Codec.decode(decoder, rx_symbols)

    IO.puts("Decoded: #{length(decoder.decoded_bits)} bits, EOM: #{decoder.eom_detected}")

    rx_bytes = decoder.decoded_bits
      |> Enum.chunk_every(8)
      |> Enum.map(fn bits ->
        Enum.reduce(Enum.with_index(bits), 0, fn {bit, idx}, acc ->
          acc + Bitwise.bsl(bit, 7 - idx)
        end)
      end)

    {:ok, :binary.list_to_bin(rx_bytes)}
  end

  defp write_wav(path, samples, sample_rate) do
    pcm = samples
      |> Enum.map(fn s -> <<max(-32768, min(32767, round(s)))::little-signed-16>> end)
      |> IO.iodata_to_binary()

    size = byte_size(pcm)
    byte_rate = sample_rate * 2

    header = <<
      "RIFF", (size + 36)::little-32, "WAVE",
      "fmt ", 16::little-32, 1::little-16, 1::little-16,
      sample_rate::little-32, byte_rate::little-32, 2::little-16, 16::little-16,
      "data", size::little-32
    >>

    File.write!(path, header <> pcm)
  end

  defp read_wav(path) do
    data = File.read!(path)

    <<"RIFF", _size::little-32, "WAVE", rest::binary>> = data

    {_fmt, pcm} = parse_wav_chunks(rest)

    for <<sample::little-signed-16 <- pcm>>, do: sample
  end

  defp parse_wav_chunks(<<"fmt ", size::little-32, _fmt::binary-size(size), rest::binary>>) do
    parse_wav_data(rest)
  end

  defp parse_wav_data(<<"data", size::little-32, pcm::binary-size(size), _rest::binary>>) do
    {:ok, pcm}
  end

  defp parse_wav_data(<<"data", _size::little-32, pcm::binary>>) do
    {:ok, pcm}
  end
end
