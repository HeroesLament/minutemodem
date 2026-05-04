//! RxCombiner: per-rig receive combiner
//!
//! Owns all inbound WattersonChannel instances for a single receiving rig.
//! Each tick, processes all channels (TX samples or silence), sums
//! frequency-coherent outputs, and returns one combined f32 block.
//!
//! This replaces the per-channel FSM architecture: instead of N separate
//! Channel.FSM processes each crossing the NIF boundary independently,
//! one RxCombiner does all N channels in a single NIF call per tick.
//!
//! Lifecycle:
//! - Created when a rig attaches to simnet
//! - Channels added/removed as other rigs attach/detach
//! - Destroyed when the rig detaches (ResourceArc GC → Drop)

use std::collections::HashMap;
use rand_chacha::ChaCha8Rng;
use rand::SeedableRng;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use super::channel::{ChannelParams, WattersonChannel};
use super::noise::NoiseGenerator;

/// Per-inbound-channel state within the combiner
struct ChannelState {
    /// The Watterson channel model instance
    watterson: WattersonChannel,
    /// What frequency the source rig is currently transmitting on
    tx_freq_hz: u32,
    /// TX samples queued for next tick (None = silence)
    pending_tx: Option<Vec<f32>>,
}

/// RxCombiner: owns all inbound channels for one receiving rig.
/// Wrapped in ResourceArc for BEAM GC integration.
pub struct RxCombiner {
    /// This rig's ID (for debugging/logging)
    rig_id: String,
    /// What frequency this rig is currently tuned to
    rx_freq_hz: u32,
    /// Sample rate (e.g. 9600)
    sample_rate: u32,
    /// Samples per tick block (e.g. 192 for 20ms @ 9600)
    block_samples: usize,
    /// Base seed for deterministic channel creation
    seed: u64,

    /// One channel per inbound rig, keyed by from_rig ID
    channels: HashMap<String, ChannelState>,

    /// Receiver noise floor generator (always present, frequency-independent)
    noise: NoiseGenerator,

    /// Reusable buffers to avoid per-tick allocation
    silence_buf: Vec<f32>,
    scratch_buf: Vec<f32>,
    output_buf: Vec<f32>,
}

impl RxCombiner {
    /// Create a new combiner for a receiving rig.
    pub fn new(
        rig_id: String,
        sample_rate: u32,
        block_samples: usize,
        noise_floor_dbm: f64,
        seed: u64,
        initial_rx_freq_hz: u32,
    ) -> Self {
        // Convert noise floor from dBm to noise power
        // Reference: 0 dBm = 1 mW. Noise power in signal domain.
        // We use the same SNR/power convention as WattersonChannel.
        let reference_signal_power = 0.125; // matches channel.rs
        let noise_snr_equivalent = -noise_floor_dbm; // higher floor = more noise
        let noise_power = reference_signal_power * 10.0_f64.powf(-noise_snr_equivalent / 10.0);

        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let noise = NoiseGenerator::new(noise_power.max(1e-12), &mut rng);

        Self {
            rig_id,
            rx_freq_hz: initial_rx_freq_hz,
            sample_rate,
            block_samples,
            seed,
            channels: HashMap::new(),
            noise,
            silence_buf: vec![0.0; block_samples],
            scratch_buf: vec![0.0; block_samples],
            output_buf: vec![0.0; block_samples],
        }
    }

    /// Add an inbound channel from another rig.
    /// If a channel from this rig already exists, it is replaced.
    pub fn add_channel(
        &mut self,
        from_rig: String,
        params: ChannelParams,
        freq_hz: u32,
    ) -> bool {
        // Deterministic per-channel seed from combiner seed + rig pair
        let channel_seed = self.seed ^ hash_rig_pair(&from_rig, &self.rig_id);

        let watterson = WattersonChannel::new(params, channel_seed);
        self.channels.insert(from_rig, ChannelState {
            watterson,
            tx_freq_hz: freq_hz,
            pending_tx: None,
        });
        true
    }

    /// Remove an inbound channel. Returns true if it existed.
    pub fn remove_channel(&mut self, from_rig: &str) -> bool {
        self.channels.remove(from_rig).is_some()
    }

    /// Queue TX samples from a source rig for the next tick.
    /// Also updates the source's TX frequency.
    pub fn push_tx(&mut self, from_rig: &str, samples: Vec<f32>, freq_hz: u32) {
        if let Some(ch) = self.channels.get_mut(from_rig) {
            ch.tx_freq_hz = freq_hz;
            ch.pending_tx = Some(samples);
        }
    }

    /// Set the frequency this receiver is tuned to.
    pub fn set_rx_frequency(&mut self, freq_hz: u32) {
        self.rx_freq_hz = freq_hz;
    }

    /// Update Watterson channel parameters for a specific inbound channel.
    /// Used when frequency changes alter propagation characteristics.
    pub fn update_channel_params(
        &mut self,
        from_rig: &str,
        new_params: ChannelParams,
    ) -> bool {
        if let Some(ch) = self.channels.get_mut(from_rig) {
            let channel_seed = self.seed ^ hash_rig_pair(from_rig, &self.rig_id);
            // Replace the Watterson channel with new params
            // TODO: could implement in-place param update to preserve fading state
            ch.watterson = WattersonChannel::new(new_params, channel_seed);
            true
        } else {
            false
        }
    }

    /// Process one tick: run all channels, sum frequency-coherent outputs.
    /// Returns the combined f32 output block.
    pub fn tick(&mut self) -> &[f32] {
        let block = self.block_samples;

        // Zero the output buffer
        for s in self.output_buf.iter_mut() {
            *s = 0.0;
        }

        // Ensure scratch buffer is sized correctly
        if self.scratch_buf.len() != block {
            self.scratch_buf.resize(block, 0.0);
        }

        for (_from_rig, ch) in self.channels.iter_mut() {
            // Take pending TX samples, or use silence
            let pending = ch.pending_tx.take();
            let has_tx = pending.is_some();
            let input: &[f32] = match &pending {
                Some(samples) if samples.len() >= block => &samples[..block],
                _ => &self.silence_buf[..block],
            };

            // Always process through Watterson to keep fading state coherent.
            // This evolves the fading taps, carrier NCO, delay lines, etc.
            let output = ch.watterson.process(input);

            // Only accumulate into combined output if frequencies match AND
            // the channel actually has TX data. Without this check, channels
            // processing silence still produce Watterson-faded AWGN noise,
            // which sums across N channels and overwhelms the receiver.
            if has_tx && ch.tx_freq_hz == self.rx_freq_hz {
                let len = output.len().min(block);
                for i in 0..len {
                    self.output_buf[i] += output[i];
                }
            }
        }

        // Add receiver noise floor (AWGN, always present regardless of frequency)
        for s in self.output_buf.iter_mut() {
            *s += self.noise.next_sample() as f32;
        }

        &self.output_buf
    }

    /// Number of inbound channels
    pub fn channel_count(&self) -> usize {
        self.channels.len()
    }

    /// Check if a channel from a specific rig exists
    pub fn has_channel(&self, from_rig: &str) -> bool {
        self.channels.contains_key(from_rig)
    }

    /// Get current RX frequency
    pub fn rx_frequency(&self) -> u32 {
        self.rx_freq_hz
    }

    /// Get channel info for debugging
    pub fn channel_info(&self) -> Vec<(String, u32, bool)> {
        self.channels
            .iter()
            .map(|(rig, ch)| {
                (
                    rig.clone(),
                    ch.tx_freq_hz,
                    ch.pending_tx.is_some(),
                )
            })
            .collect()
    }
}

/// Deterministic hash of a rig pair for per-channel seed derivation.
fn hash_rig_pair(from_rig: &str, to_rig: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    from_rig.hash(&mut hasher);
    to_rig.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_params() -> ChannelParams {
        ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 0,
            doppler_bandwidth_hz: 0.0,
            snr_db: 50.0,
            carrier_freq_hz: 1800.0,
        }
    }

    #[test]
    fn test_combiner_new() {
        let c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);
        assert_eq!(c.channel_count(), 0);
        assert_eq!(c.rx_frequency(), 7_300_000);
    }

    #[test]
    fn test_add_remove_channel() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);

        c.add_channel("rig_b".to_string(), make_test_params(), 7_300_000);
        assert_eq!(c.channel_count(), 1);
        assert!(c.has_channel("rig_b"));

        c.add_channel("rig_c".to_string(), make_test_params(), 7_300_000);
        assert_eq!(c.channel_count(), 2);

        assert!(c.remove_channel("rig_b"));
        assert_eq!(c.channel_count(), 1);
        assert!(!c.has_channel("rig_b"));

        // Idempotent remove
        assert!(!c.remove_channel("rig_b"));
    }

    #[test]
    fn test_tick_silence_produces_noise() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);
        c.add_channel("rig_b".to_string(), make_test_params(), 7_300_000);

        let output = c.tick();
        assert_eq!(output.len(), 192);

        // Output should be non-zero (noise floor + channel noise)
        let energy: f64 = output.iter().map(|&s| (s as f64).powi(2)).sum();
        assert!(energy > 0.0, "Output should contain noise");
    }

    #[test]
    fn test_tick_with_tx() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);
        c.add_channel("rig_b".to_string(), make_test_params(), 7_300_000);

        // Push a tone through
        let tone: Vec<f32> = (0..192)
            .map(|i| (2.0 * std::f64::consts::PI * 1800.0 * i as f64 / 9600.0).cos() as f32 * 0.5)
            .collect();

        c.push_tx("rig_b", tone.clone(), 7_300_000);

        let output = c.tick();
        assert_eq!(output.len(), 192);

        // With 50dB SNR and static channel, output should have significant energy
        let energy: f64 = output.iter().map(|&s| (s as f64).powi(2)).sum();
        let input_energy: f64 = tone.iter().map(|&s| (s as f64).powi(2)).sum();
        assert!(energy > input_energy * 0.1, "TX signal should pass through");
    }

    #[test]
    fn test_frequency_filtering() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);

        // Two channels: one on-frequency, one off
        c.add_channel("rig_b".to_string(), make_test_params(), 7_300_000); // match
        c.add_channel("rig_c".to_string(), make_test_params(), 5_000_000); // no match

        let tone: Vec<f32> = (0..192)
            .map(|i| (2.0 * std::f64::consts::PI * 1800.0 * i as f64 / 9600.0).cos() as f32 * 0.5)
            .collect();

        // Only rig_c transmits (wrong frequency)
        c.push_tx("rig_c", tone.clone(), 5_000_000);

        let output_off = c.tick();
        let energy_off: f64 = output_off.iter().map(|&s| (s as f64).powi(2)).sum();

        // Now rig_b transmits (right frequency)
        c.push_tx("rig_b", tone.clone(), 7_300_000);

        let output_on = c.tick();
        let energy_on: f64 = output_on.iter().map(|&s| (s as f64).powi(2)).sum();

        // On-frequency should have much more energy than off-frequency
        assert!(
            energy_on > energy_off * 5.0,
            "On-freq energy {} should be >> off-freq energy {}",
            energy_on,
            energy_off
        );
    }

    #[test]
    fn test_frequency_retune() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);
        c.add_channel("rig_b".to_string(), make_test_params(), 5_000_000);

        let tone: Vec<f32> = (0..192)
            .map(|i| (2.0 * std::f64::consts::PI * 1800.0 * i as f64 / 9600.0).cos() as f32 * 0.5)
            .collect();

        // B is on 5 MHz, we're on 7.3 MHz — shouldn't hear it
        c.push_tx("rig_b", tone.clone(), 5_000_000);
        let out1 = c.tick();
        let e1: f64 = out1.iter().map(|&s| (s as f64).powi(2)).sum();

        // Retune to 5 MHz — now we should hear B
        c.set_rx_frequency(5_000_000);
        c.push_tx("rig_b", tone.clone(), 5_000_000);
        let out2 = c.tick();
        let e2: f64 = out2.iter().map(|&s| (s as f64).powi(2)).sum();

        assert!(
            e2 > e1 * 5.0,
            "After retune, energy {} should be >> previous {}",
            e2, e1
        );
    }

    #[test]
    fn test_multiple_channels_sum() {
        let mut c = RxCombiner::new("rig_a".to_string(), 9600, 192, -100.0, 42, 7_300_000);

        // Add two on-frequency channels
        c.add_channel("rig_b".to_string(), make_test_params(), 7_300_000);
        c.add_channel("rig_c".to_string(), make_test_params(), 7_300_000);

        let tone: Vec<f32> = (0..192)
            .map(|i| (2.0 * std::f64::consts::PI * 1800.0 * i as f64 / 9600.0).cos() as f32 * 0.5)
            .collect();

        // Only B transmits
        c.push_tx("rig_b", tone.clone(), 7_300_000);
        let out1 = c.tick();
        let e1: f64 = out1.iter().map(|&s| (s as f64).powi(2)).sum();

        // Both B and C transmit
        c.push_tx("rig_b", tone.clone(), 7_300_000);
        c.push_tx("rig_c", tone.clone(), 7_300_000);
        let out2 = c.tick();
        let e2: f64 = out2.iter().map(|&s| (s as f64).powi(2)).sum();

        // Two signals should have more energy than one
        assert!(
            e2 > e1 * 1.5,
            "Two TX energy {} should be > one TX energy {}",
            e2, e1
        );
    }
}