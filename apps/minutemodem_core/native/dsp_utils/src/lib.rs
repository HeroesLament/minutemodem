// lib.rs
use rustler::{Binary, Env, NifResult, OwnedBinary};

mod fft;
mod window;

#[rustler::nif]
fn compute_fft_db(
    audio: Binary,           // f32-le samples
    fft_size: usize,
    window: &str,            // "hann", "hamming", "none"
) -> NifResult<OwnedBinary> {
    // Returns f32-le dB magnitude bins (fft_size/2)
    fft::compute_db(audio.as_slice(), fft_size, window)
}

#[rustler::nif]
fn real_to_iq(
    audio: Binary,           // f32-le real samples  
    decimate: usize,         // output every Nth sample
) -> NifResult<OwnedBinary> {
    // Hilbert transform → analytic → decimate
    // Returns interleaved f32-le I/Q pairs
    hilbert::to_iq(audio.as_slice(), decimate)
}

rustler::init!("Elixir.DspUtils.Native", [compute_fft_db, real_to_iq]);