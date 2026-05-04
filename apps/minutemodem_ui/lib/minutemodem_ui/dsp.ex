defmodule MinuteModemUI.DSP do
  @moduledoc """
  DSP utilities for driving UI canvases.

  Thin Elixir wrapper over the `ui_dsp` Rust NIF. Handles sample format
  conversion so callers can pass whatever the audio path gives them.

  ## Usage

      # Spectrogram: raw s16le PCM → dB bins
      bins = MinuteModemUI.DSP.fft_db(pcm_binary, 512, :hann)
      WxMVU.GLCanvas.send_data(:spectrogram, {:bins, bins})

      # Constellation: raw s16le PCM → I/Q pairs
      iq = MinuteModemUI.DSP.to_iq(pcm_binary, decimate: 4)
      WxMVU.GLCanvas.send_data(:constellation, {:samples, iq})

      # Meters: raw s16le PCM → {rms_dbfs, peak_dbfs}
      {rms, peak} = MinuteModemUI.DSP.levels(pcm_binary)
  """

  alias MinuteModemUI.DSP.Native

  # ---------------------------------------------------------------------------
  # Spectrogram
  # ---------------------------------------------------------------------------

  @doc """
  Compute FFT magnitude bins in dB from audio samples.

  Accepts either:
    - s16le binary (from Membrane / AudioEndpoint)
    - list of s16le integers (from Rig.Audio broadcast)

  Returns a binary of `fft_size / 2` f32-le dB values.

  ## Options
    - `window` — `:hann` (default), `:hamming`, `:blackman`, or `:none`
  """
  @spec fft_db(binary() | [integer()], pos_integer(), atom()) :: binary()
  def fft_db(samples, fft_size \\ 512, window \\ :hann)

  def fft_db(samples, fft_size, window) when is_binary(samples) do
    Native.compute_fft_db(samples, fft_size, window_str(window))
  end

  def fft_db(samples, fft_size, window) when is_list(samples) do
    Native.compute_fft_db(samples_to_s16le(samples), fft_size, window_str(window))
  end

  # ---------------------------------------------------------------------------
  # Constellation
  # ---------------------------------------------------------------------------

  @doc """
  Convert real audio samples to analytic (I/Q) signal via Hilbert transform.

  Accepts s16le binary or list of s16le integers.
  Returns interleaved f32-le I/Q pairs.

  ## Options
    - `decimate` — output every Nth pair (default: 1)
  """
  @spec to_iq(binary() | [integer()], keyword()) :: binary()
  def to_iq(samples, opts \\ [])

  def to_iq(samples, opts) when is_binary(samples) do
    decimate = Keyword.get(opts, :decimate, 1)
    Native.real_to_iq(samples, decimate)
  end

  def to_iq(samples, opts) when is_list(samples) do
    decimate = Keyword.get(opts, :decimate, 1)
    Native.real_to_iq(samples_to_s16le(samples), decimate)
  end

  # ---------------------------------------------------------------------------
  # Meters
  # ---------------------------------------------------------------------------

  @doc """
  Compute RMS and peak levels in a single pass.

  Returns `{rms_dbfs, peak_dbfs}` as floats.
  Silence returns `{-120.0, -120.0}`.
  """
  @spec levels(binary() | [integer()]) :: {float(), float()}
  def levels(samples) when is_binary(samples) do
    <<rms::float-32-little, peak::float-32-little>> = Native.audio_levels(samples)
    {rms, peak}
  end

  def levels(samples) when is_list(samples) do
    levels(samples_to_s16le(samples))
  end

  @doc "Compute RMS level in dBFS."
  @spec rms_dbfs(binary() | [integer()]) :: float()
  def rms_dbfs(samples) when is_binary(samples), do: Native.rms_dbfs(samples)
  def rms_dbfs(samples) when is_list(samples), do: Native.rms_dbfs(samples_to_s16le(samples))

  @doc "Compute peak level in dBFS."
  @spec peak_dbfs(binary() | [integer()]) :: float()
  def peak_dbfs(samples) when is_binary(samples), do: Native.peak_dbfs(samples)
  def peak_dbfs(samples) when is_list(samples), do: Native.peak_dbfs(samples_to_s16le(samples))

  # ---------------------------------------------------------------------------
  # Sample format conversion
  # ---------------------------------------------------------------------------

  @doc """
  Convert a list of s16le integer samples to a binary.

  This is the format conversion needed because `Rig.Audio` broadcasts
  samples as integer lists, but the NIF expects contiguous s16le binary.
  """
  @spec samples_to_s16le([integer()]) :: binary()
  def samples_to_s16le(samples) when is_list(samples) do
    for s <- samples, into: <<>> do
      <<s::signed-little-16>>
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp window_str(:hann), do: "hann"
  defp window_str(:hamming), do: "hamming"
  defp window_str(:blackman), do: "blackman"
  defp window_str(:none), do: "none"
  defp window_str(str) when is_binary(str), do: str
end
