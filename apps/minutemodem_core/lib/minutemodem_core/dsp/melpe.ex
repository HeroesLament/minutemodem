defmodule MinuteModemCore.DSP.Melpe do
  @moduledoc """
  MELPe 600 bps vocoder for STANAG 4591.

  Wraps `melpe-rs` via Rustler NIF. Encoder and decoder are stateful
  managed resources — create one, feed superframes, reset when needed.

  ## Codec geometry

    - Sample rate: 8000 Hz
    - Superframe: 540 samples (67.5 ms) → 6 bytes (48 bits)
    - Bitrate: 600 bps

  ## Usage

      enc = MinuteModemCore.DSP.Melpe.encoder_new()
      bitstream = MinuteModemCore.DSP.Melpe.encode(enc, samples_540)

      dec = MinuteModemCore.DSP.Melpe.decoder_new()
      audio = MinuteModemCore.DSP.Melpe.decode(dec, bitstream)
  """

  use Rustler,
    otp_app: :minutemodem_core,
    crate: :melpe

  # ============================================================================
  # Encoder
  # ============================================================================

  def encoder_new(), do: :erlang.nif_error(:nif_not_loaded)
  def encode(_encoder, _samples), do: :erlang.nif_error(:nif_not_loaded)
  def encoder_reset(_encoder), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Decoder
  # ============================================================================

  def decoder_new(), do: :erlang.nif_error(:nif_not_loaded)
  def decode(_decoder, _bitstream), do: :erlang.nif_error(:nif_not_loaded)
  def decoder_reset(_decoder), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Info
  # ============================================================================

  def codec_info(), do: :erlang.nif_error(:nif_not_loaded)
end
