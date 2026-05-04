//! Channel Physics NIF for MinuteModem SimNet
//!
//! Implements MIL-STD-188-110D Appendix E Watterson channel model
//! with two-path Rayleigh fading, configurable delay spread, and AWGN.
//!
//! Two interfaces:
//! 1. Legacy slab-based: individual channels keyed by integer ID
//! 2. RxCombiner: per-rig combiner owning all inbound channels (ResourceArc)

pub mod channel;
pub mod fading;
pub mod noise;
pub mod rx_combiner;
pub mod slab;

use rustler::{Binary, Env, NifResult, OwnedBinary, ResourceArc};
use std::sync::Mutex;

use channel::{ChannelParams, WattersonChannel};
use rx_combiner::RxCombiner;
use slab::ChannelSlab;

// Global slab for legacy channel storage - now with per-channel locking
lazy_static::lazy_static! {
    static ref CHANNELS: ChannelSlab<WattersonChannel> = ChannelSlab::new(1024);
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

// Newtype wrapper for ResourceArc (orphan rule: can't impl foreign trait on foreign type)
pub struct CombinerResource(Mutex<RxCombiner>);

#[rustler::resource_impl]
impl rustler::Resource for CombinerResource {}

rustler::init!("Elixir.MinutemodemSimnet.Physics.Nif");

// =========================================================================
// Legacy slab-based channel interface (existing, unchanged)
// =========================================================================

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

    let output = CHANNELS
        .with_channel_mut(channel_id, |channel| channel.process(&samples))
        .ok_or_else(|| rustler::Error::Term(Box::new("channel_not_found")))?;

    let output_byte_len = output.len() * 4;
    let mut owned = OwnedBinary::new(output_byte_len)
        .ok_or_else(|| rustler::Error::Term(Box::new("binary_alloc_failed")))?;

    let out_slice = owned.as_mut_slice();
    for (i, sample) in output.iter().enumerate() {
        let bytes = sample.to_ne_bytes();
        out_slice[i * 4..(i + 1) * 4].copy_from_slice(&bytes);
    }

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

// =========================================================================
// RxCombiner interface (new, ResourceArc-based)
// =========================================================================

/// Creates a new RxCombiner. Returns a ResourceArc reference.
#[rustler::nif]
fn combiner_new(
    rig_id: String,
    sample_rate: u32,
    block_samples: u32,
    noise_floor_dbm: f64,
    seed: u64,
    initial_rx_freq_hz: u32,
) -> ResourceArc<CombinerResource> {
    let combiner = RxCombiner::new(
        rig_id,
        sample_rate,
        block_samples as usize,
        noise_floor_dbm,
        seed,
        initial_rx_freq_hz,
    );
    ResourceArc::new(CombinerResource(Mutex::new(combiner)))
}

/// Adds an inbound channel to the combiner.
#[rustler::nif]
fn combiner_add_channel(
    combiner: ResourceArc<CombinerResource>,
    from_rig: String,
    params: ChannelParams,
    freq_hz: u32,
) -> bool {
    combiner
        .0
        .lock()
        .unwrap()
        .add_channel(from_rig, params, freq_hz)
}

/// Removes an inbound channel from the combiner.
#[rustler::nif]
fn combiner_remove_channel(
    combiner: ResourceArc<CombinerResource>,
    from_rig: String,
) -> bool {
    combiner.0.lock().unwrap().remove_channel(&from_rig)
}

/// Queues TX samples from a source rig for the next tick.
#[rustler::nif]
fn combiner_push_tx(
    combiner: ResourceArc<CombinerResource>,
    from_rig: String,
    samples: Binary,
    freq_hz: u32,
) -> rustler::Atom {
    let input_bytes = samples.as_slice();
    let sample_vec: Vec<f32> = input_bytes
        .chunks_exact(4)
        .map(|b| f32::from_ne_bytes(b.try_into().unwrap()))
        .collect();

    combiner
        .0
        .lock()
        .unwrap()
        .push_tx(&from_rig, sample_vec, freq_hz);
    atoms::ok()
}

/// Sets the receiver's tuned frequency.
#[rustler::nif]
fn combiner_set_rx_freq(
    combiner: ResourceArc<CombinerResource>,
    freq_hz: u32,
) -> rustler::Atom {
    combiner.0.lock().unwrap().set_rx_frequency(freq_hz);
    atoms::ok()
}

/// Updates Watterson params for a specific inbound channel.
#[rustler::nif]
fn combiner_update_channel_params(
    combiner: ResourceArc<CombinerResource>,
    from_rig: String,
    params: ChannelParams,
) -> bool {
    combiner
        .0
        .lock()
        .unwrap()
        .update_channel_params(&from_rig, params)
}

/// Processes one tick: runs all channels, sums coherent outputs.
/// Returns combined f32 binary.
#[rustler::nif]
fn combiner_tick<'a>(
    env: Env<'a>,
    combiner: ResourceArc<CombinerResource>,
) -> NifResult<Binary<'a>> {
    let mut guard = combiner.0.lock().unwrap();
    let output = guard.tick();

    let byte_len = output.len() * 4;
    let mut owned = OwnedBinary::new(byte_len)
        .ok_or_else(|| rustler::Error::Term(Box::new("binary_alloc_failed")))?;

    let out_slice = owned.as_mut_slice();
    for (i, &sample) in output.iter().enumerate() {
        let bytes = sample.to_ne_bytes();
        out_slice[i * 4..(i + 1) * 4].copy_from_slice(&bytes);
    }

    Ok(owned.release(env))
}

/// Returns the number of inbound channels.
#[rustler::nif]
fn combiner_channel_count(
    combiner: ResourceArc<CombinerResource>,
) -> usize {
    combiner.0.lock().unwrap().channel_count()
}

/// Returns debug info about combiner channels.
/// Each entry: {from_rig, tx_freq_hz, has_pending_tx}
#[rustler::nif]
fn combiner_info(
    combiner: ResourceArc<CombinerResource>,
) -> Vec<(String, u32, bool)> {
    combiner.0.lock().unwrap().channel_info()
}
