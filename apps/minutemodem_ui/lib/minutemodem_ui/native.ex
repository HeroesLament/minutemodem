defmodule MinuteModemUI.DSP.Native do
  @moduledoc false
  # Raw NIF bindings — use MinuteModemUI.DSP for the public API.

  use Rustler,
    otp_app: :minutemodem_ui,
    crate: :ui_dsp

  def compute_fft_db(_audio, _fft_size, _window), do: :erlang.nif_error(:nif_not_loaded)
  def compute_fft_db_f32(_audio, _fft_size, _window), do: :erlang.nif_error(:nif_not_loaded)
  def real_to_iq(_audio, _decimate), do: :erlang.nif_error(:nif_not_loaded)
  def real_to_iq_f32(_audio, _decimate), do: :erlang.nif_error(:nif_not_loaded)
  def rms_dbfs(_audio), do: :erlang.nif_error(:nif_not_loaded)
  def peak_dbfs(_audio), do: :erlang.nif_error(:nif_not_loaded)
  def audio_levels(_audio), do: :erlang.nif_error(:nif_not_loaded)
end
