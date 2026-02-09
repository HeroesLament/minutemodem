use melpe_codec::core_types::{SUPERFRAME_BYTES_600, SUPERFRAME_SAMPLES};
use melpe_codec::decoder::Decoder;
use melpe_codec::encoder::Encoder;
use rustler::{Env, NifResult, ResourceArc, Term};
use std::sync::Mutex;

// ── Resource wrappers (Mutex for BEAM scheduler safety) ─────────────────────

pub struct EncoderResource(Mutex<Encoder>);
pub struct DecoderResource(Mutex<Decoder>);

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(EncoderResource, env);
    rustler::resource!(DecoderResource, env);
    true
}

// ── Encoder NIFs ────────────────────────────────────────────────────────────

#[rustler::nif]
fn encoder_new() -> ResourceArc<EncoderResource> {
    ResourceArc::new(EncoderResource(Mutex::new(Encoder::new())))
}

/// 540 f64 samples → 6-byte binary
#[rustler::nif]
fn encode(encoder: ResourceArc<EncoderResource>, samples: Vec<f64>) -> NifResult<Vec<u8>> {
    let mut enc = encoder
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock_poisoned")))?;

    if samples.len() != SUPERFRAME_SAMPLES {
        return Err(rustler::Error::Term(Box::new(format!(
            "expected {} samples, got {}",
            SUPERFRAME_SAMPLES,
            samples.len()
        ))));
    }

    let mut input = [0.0f32; SUPERFRAME_SAMPLES];
    for (i, &s) in samples.iter().enumerate() {
        input[i] = s as f32;
    }

    let mut bitstream = [0u8; SUPERFRAME_BYTES_600];
    enc.encode(&input, &mut bitstream);
    Ok(bitstream.to_vec())
}

#[rustler::nif]
fn encoder_reset(encoder: ResourceArc<EncoderResource>) -> NifResult<rustler::Atom> {
    encoder
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock_poisoned")))?
        .reset();
    Ok(rustler::types::atom::ok())
}

// ── Decoder NIFs ────────────────────────────────────────────────────────────

#[rustler::nif]
fn decoder_new() -> ResourceArc<DecoderResource> {
    ResourceArc::new(DecoderResource(Mutex::new(Decoder::new())))
}

/// 6-byte binary → 540 f64 samples
#[rustler::nif]
fn decode(decoder: ResourceArc<DecoderResource>, bitstream: Vec<u8>) -> NifResult<Vec<f64>> {
    let mut dec = decoder
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock_poisoned")))?;

    if bitstream.len() != SUPERFRAME_BYTES_600 {
        return Err(rustler::Error::Term(Box::new(format!(
            "expected {} bytes, got {}",
            SUPERFRAME_BYTES_600,
            bitstream.len()
        ))));
    }

    let mut bs = [0u8; SUPERFRAME_BYTES_600];
    bs.copy_from_slice(&bitstream);

    let mut output = [0.0f32; SUPERFRAME_SAMPLES];
    dec.decode(&bs, &mut output);
    Ok(output.iter().map(|&s| s as f64).collect())
}

#[rustler::nif]
fn decoder_reset(decoder: ResourceArc<DecoderResource>) -> NifResult<rustler::Atom> {
    decoder
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock_poisoned")))?
        .reset();
    Ok(rustler::types::atom::ok())
}

// ── Info ────────────────────────────────────────────────────────────────────

#[rustler::nif]
fn codec_info() -> Vec<(String, usize)> {
    vec![
        ("superframe_samples".into(), SUPERFRAME_SAMPLES),
        ("superframe_bytes".into(), SUPERFRAME_BYTES_600),
        ("sample_rate".into(), 8000),
        ("bitrate".into(), 600),
        ("frames_per_superframe".into(), 3),
        ("frame_samples".into(), 180),
    ]
}

rustler::init!("Elixir.MinuteModemCore.DSP.Melpe", load = load);
