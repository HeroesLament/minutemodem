//! ui_dsp — DSP NIFs for the MinuteModem remote UI.
//!
//! Provides fast signal processing for driving the UI canvases:
//!   - Spectrogram (waterfall) ← FFT magnitude bins in dB
//!   - Constellation (I/Q scatter) ← Hilbert analytic signal
//!   - Level meters (VU / peak) ← RMS and peak detection
//!
//! All functions accept raw sample binaries and return raw result binaries,
//! matching the conventions used by the GLCanvas modules.

use rustler::{Binary, Env, NifResult, OwnedBinary};

mod fft;
mod analytic;
mod meters;

// ---------------------------------------------------------------------------
// Spectrogram: s16le samples → f32-le dB magnitude bins
// ---------------------------------------------------------------------------

/// Compute FFT magnitude bins in dB from s16le PCM samples.
///
/// ## Arguments
///   - `audio` — binary of s16le samples (2 bytes per sample)
///   - `fft_size` — FFT length (e.g. 512, 1024). Must be power of 2.
///   - `window` — window function: "hann", "hamming", "blackman", or "none"
///
/// ## Returns
///   Binary of `fft_size / 2` f32-le dB values (positive frequencies only).
///   Suitable for feeding directly to `Spectrogram.handle_data({:bins, binary})`.
#[rustler::nif]
fn compute_fft_db<'a>(
    env: Env<'a>,
    audio: Binary,
    fft_size: usize,
    window: &str,
) -> NifResult<Binary<'a>> {
    let result_bytes = fft::compute_db(audio.as_slice(), fft_size, window);

    let mut owned = OwnedBinary::new(result_bytes.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    owned.as_mut_slice().copy_from_slice(&result_bytes);
    Ok(owned.release(env))
}

/// Same as `compute_fft_db/3` but input is f32-le normalized samples.
#[rustler::nif]
fn compute_fft_db_f32<'a>(
    env: Env<'a>,
    audio: Binary,
    fft_size: usize,
    window: &str,
) -> NifResult<Binary<'a>> {
    let result_bytes = fft::compute_db_f32(audio.as_slice(), fft_size, window);

    let mut owned = OwnedBinary::new(result_bytes.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    owned.as_mut_slice().copy_from_slice(&result_bytes);
    Ok(owned.release(env))
}

// ---------------------------------------------------------------------------
// Constellation: s16le samples → f32-le interleaved I/Q pairs
// ---------------------------------------------------------------------------

/// Convert real-valued s16le samples to analytic (I/Q) signal.
///
/// Uses frequency-domain Hilbert transform to extract the analytic signal,
/// then decimates the output.
///
/// ## Arguments
///   - `audio` — binary of s16le samples
///   - `decimate` — output every Nth I/Q pair (1 = no decimation)
///
/// ## Returns
///   Binary of interleaved f32-le I, Q, I, Q, ... pairs.
///   Suitable for feeding to `Constellation.handle_data({:samples, binary})`.
#[rustler::nif]
fn real_to_iq<'a>(
    env: Env<'a>,
    audio: Binary,
    decimate: usize,
) -> NifResult<Binary<'a>> {
    let result_bytes = analytic::real_to_iq(audio.as_slice(), decimate);

    let mut owned = OwnedBinary::new(result_bytes.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    owned.as_mut_slice().copy_from_slice(&result_bytes);
    Ok(owned.release(env))
}

/// Same as `real_to_iq/2` but input is f32-le normalized samples.
#[rustler::nif]
fn real_to_iq_f32<'a>(
    env: Env<'a>,
    audio: Binary,
    decimate: usize,
) -> NifResult<Binary<'a>> {
    let result_bytes = analytic::real_to_iq_f32(audio.as_slice(), decimate);

    let mut owned = OwnedBinary::new(result_bytes.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    owned.as_mut_slice().copy_from_slice(&result_bytes);
    Ok(owned.release(env))
}

// ---------------------------------------------------------------------------
// Meters: s16le samples → dBFS levels
// ---------------------------------------------------------------------------

/// Compute RMS level in dBFS from s16le audio.
///
/// Returns a float. Silence = -120.0, full scale ≈ 0.0.
#[rustler::nif]
fn rms_dbfs(audio: Binary) -> f32 {
    meters::rms_dbfs(audio.as_slice())
}

/// Compute peak level in dBFS from s16le audio.
#[rustler::nif]
fn peak_dbfs(audio: Binary) -> f32 {
    meters::peak_dbfs(audio.as_slice())
}

/// Compute both RMS and peak in a single pass.
///
/// Returns a binary of two f32-le values: [rms_dbfs, peak_dbfs].
#[rustler::nif]
fn audio_levels<'a>(
    env: Env<'a>,
    audio: Binary,
) -> NifResult<Binary<'a>> {
    let result_bytes = meters::levels(audio.as_slice());

    let mut owned = OwnedBinary::new(result_bytes.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    owned.as_mut_slice().copy_from_slice(&result_bytes);
    Ok(owned.release(env))
}

rustler::init!(
    "Elixir.MinuteModemUI.DSP.Native",
    [
        compute_fft_db,
        compute_fft_db_f32,
        real_to_iq,
        real_to_iq_f32,
        rms_dbfs,
        peak_dbfs,
        audio_levels
    ]
);
