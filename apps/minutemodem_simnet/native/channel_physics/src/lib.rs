//! Channel Physics NIF for MinuteModem SimNet
//!
//! Implements MIL-STD-188-110D Appendix E Watterson channel model
//! with two-path Rayleigh fading, configurable delay spread, and AWGN.

pub mod channel;
pub mod fading;
pub mod noise;
pub mod slab;

use rustler::{Binary, Env, NifResult, OwnedBinary};

use channel::{ChannelParams, WattersonChannel};
use slab::ChannelSlab;

// Global slab for channel storage - now with per-channel locking
lazy_static::lazy_static! {
    static ref CHANNELS: ChannelSlab<WattersonChannel> = ChannelSlab::new(1024);
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

rustler::init!("Elixir.MinutemodemSimnet.Physics.Nif");

/// Creates a new WattersonChannel and returns its slab handle.
#[rustler::nif]
fn create_channel(params: ChannelParams, seed: u64) -> NifResult<(rustler::Atom, u64)> {
    let channel = WattersonChannel::new(params, seed);

    match CHANNELS.insert(channel) {
        Some(id) => Ok((atoms::ok(), id)),
        None => Err(rustler::Error::Term(Box::new("slab_full"))),
    }
}

/// Processes a block of samples through the channel.
/// Input: f32 samples as binary (native endian)
/// Output: f32 samples as binary (native endian, same length)
#[rustler::nif]
fn process_block<'a>(
    env: Env<'a>,
    channel_id: u64,
    input: Binary,
) -> NifResult<(rustler::Atom, Binary<'a>)> {
    // Convert input binary to f32 samples
    let input_bytes = input.as_slice();
    if input_bytes.len() % 4 != 0 {
        return Err(rustler::Error::Term(Box::new("invalid_sample_size")));
    }

    let num_samples = input_bytes.len() / 4;
    let mut samples: Vec<f32> = Vec::with_capacity(num_samples);

    for chunk in input_bytes.chunks_exact(4) {
        let bytes: [u8; 4] = chunk.try_into().unwrap();
        samples.push(f32::from_ne_bytes(bytes));
    }

    // Lock only this channel and process
    let output = CHANNELS
        .with_channel_mut(channel_id, |channel| channel.process(&samples))
        .ok_or_else(|| rustler::Error::Term(Box::new("channel_not_found")))?;

    // Allocate output binary on BEAM heap
    let output_byte_len = output.len() * 4;
    let mut owned = OwnedBinary::new(output_byte_len)
        .ok_or_else(|| rustler::Error::Term(Box::new("binary_alloc_failed")))?;

    // Copy f32 samples as native-endian bytes into the binary
    let out_slice = owned.as_mut_slice();
    for (i, sample) in output.iter().enumerate() {
        let bytes = sample.to_ne_bytes();
        out_slice[i * 4..(i + 1) * 4].copy_from_slice(&bytes);
    }

    // Release ownership to BEAM garbage collector
    Ok((atoms::ok(), owned.release(env)))
}

/// Advances channel state by N samples without processing.
#[rustler::nif]
fn advance(channel_id: u64, num_samples: u64) -> NifResult<rustler::Atom> {
    CHANNELS
        .with_channel_mut(channel_id, |channel| {
            channel.advance(num_samples as usize);
        })
        .ok_or_else(|| rustler::Error::Term(Box::new("channel_not_found")))?;

    Ok(atoms::ok())
}

/// Destroys a channel and frees its slab slot.
#[rustler::nif]
fn destroy_channel(channel_id: u64) -> NifResult<rustler::Atom> {
    CHANNELS.remove(channel_id);
    Ok(atoms::ok())
}

/// Gets the current state of a channel for debugging/telemetry.
#[rustler::nif]
fn get_state(channel_id: u64) -> NifResult<(rustler::Atom, channel::ChannelState)> {
    let state = CHANNELS
        .with_channel(channel_id, |channel| channel.get_state())
        .ok_or_else(|| rustler::Error::Term(Box::new("channel_not_found")))?;

    Ok((atoms::ok(), state))
}

/// Returns the number of active channels in the slab.
#[rustler::nif]
fn channel_count() -> NifResult<u64> {
    Ok(CHANNELS.count() as u64)
}