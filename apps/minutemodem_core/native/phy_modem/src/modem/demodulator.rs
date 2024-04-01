//! Generic Demodulator
//!
//! Symmetric with the Modulator - uses the same traits for
//! matched filtering and symbol decision.

use crate::traits::{Carrier, Constellation, PulseShape, SymbolTiming};
use std::f64::consts::PI;

/// Soft I/Q output with timing information
#[derive(Debug, Clone)]
pub struct SoftIQ {
    /// I/Q samples at symbol rate
    pub iq: Vec<(f64, f64)>,
    /// Detected timing offset (sample index within symbol period)
    pub timing_offset: usize,
}

/// Generic demodulator composed of trait implementations
///
/// Uses two-pass demodulation for burst timing:
/// 1. Mix down, filter, accumulate energy at each timing phase
/// 2. Decimate at optimal phase for symbol decisions
pub struct Demodulator<C, P, K, T>
where
    C: Constellation,
    P: PulseShape,
    K: Carrier,
    T: SymbolTiming,
{
    constellation: C,
    pulse: P,
    carrier: K,
    timing: T,
    i_history: Vec<f64>,
    q_history: Vec<f64>,
}

impl<C, P, K, T> Demodulator<C, P, K, T>
where
    C: Constellation,
    P: PulseShape,
    K: Carrier,
    T: SymbolTiming,
{
    /// Create a new demodulator
    pub fn new(constellation: C, pulse: P, carrier: K, timing: T) -> Self {
        let filter_len = pulse.filter_len();
        Self {
            constellation,
            pulse,
            carrier,
            timing,
            i_history: vec![0.0; filter_len],
            q_history: vec![0.0; filter_len],
        }
    }

    /// Core demodulation: mix down and filter to baseband I/Q at sample rate
    /// 
    /// Returns filtered I/Q for every input sample (not decimated)
    fn demodulate_to_baseband(&mut self, samples: &[i16]) -> Vec<(f64, f64)> {
        let sample_rate = self.timing.sample_rate() as f64;
        let carrier_freq = self.carrier.frequency();

        let mut filtered_iq: Vec<(f64, f64)> = Vec::with_capacity(samples.len());

        for (sample_idx, &sample) in samples.iter().enumerate() {
            let sample_f = sample as f64 / 32768.0;

            // Mix down to baseband
            let t = sample_idx as f64 / sample_rate;
            let phase = 2.0 * PI * carrier_freq * t;

            let lo_i = phase.cos();
            let lo_q = -phase.sin();

            let mixed_i = sample_f * lo_i * 2.0;
            let mixed_q = sample_f * lo_q * 2.0;

            // Push through matched filter
            self.i_history.rotate_left(1);
            self.q_history.rotate_left(1);

            let last = self.i_history.len() - 1;
            self.i_history[last] = mixed_i;
            self.q_history[last] = mixed_q;

            // Apply matched filter
            let filtered_i = self.pulse.filter(&self.i_history);
            let filtered_q = self.pulse.filter(&self.q_history);

            filtered_iq.push((filtered_i, filtered_q));
        }

        filtered_iq
    }

    /// Find optimal timing phase using energy detection
    fn find_timing_phase(&self, filtered_iq: &[(f64, f64)]) -> usize {
        let sps = self.timing.samples_per_symbol();
        let skip_samples = 2 * self.pulse.span_symbols() * sps;

        let mut phase_energy = vec![0.0; sps];

        for (i, &(fi, fq)) in filtered_iq.iter().enumerate().skip(skip_samples) {
            let phase_idx = i % sps;
            phase_energy[phase_idx] += fi * fi + fq * fq;
        }

        phase_energy
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
            .map(|(i, _)| i)
            .unwrap_or(0)
    }

    /// Decimate I/Q at given timing phase
    fn decimate_iq(&self, filtered_iq: &[(f64, f64)], timing_phase: usize) -> Vec<(f64, f64)> {
        let sps = self.timing.samples_per_symbol();
        
        filtered_iq
            .iter()
            .enumerate()
            .filter(|(i, _)| i % sps == timing_phase)
            .map(|(_, &iq)| iq)
            .collect()
    }

    /// Demodulate to soft I/Q at symbol rate
    ///
    /// Returns I/Q samples decimated at optimal timing phase.
    /// Use this when you need to defer hard decisions (e.g., for 110D RX).
    ///
    /// # Arguments
    /// * `samples` - Audio samples as i16
    ///
    /// # Returns
    /// SoftIQ containing I/Q at symbol rate and detected timing offset
    pub fn demodulate_to_iq(&mut self, samples: &[i16]) -> SoftIQ {
        if samples.is_empty() {
            return SoftIQ {
                iq: Vec::new(),
                timing_offset: 0,
            };
        }

        let filtered_iq = self.demodulate_to_baseband(samples);
        let timing_offset = self.find_timing_phase(&filtered_iq);
        let iq = self.decimate_iq(&filtered_iq, timing_offset);

        SoftIQ { iq, timing_offset }
    }

    /// Demodulate to soft I/Q with known timing (no timing search)
    ///
    /// Use this when timing is already synchronized (e.g., after preamble).
    pub fn demodulate_to_iq_with_timing(&mut self, samples: &[i16], timing_offset: usize) -> SoftIQ {
        if samples.is_empty() {
            return SoftIQ {
                iq: Vec::new(),
                timing_offset,
            };
        }

        let filtered_iq = self.demodulate_to_baseband(samples);
        let iq = self.decimate_iq(&filtered_iq, timing_offset);

        SoftIQ { iq, timing_offset }
    }

    /// Demodulate audio samples to symbols (hard decisions)
    ///
    /// Uses energy-based timing recovery to find optimal sample phase,
    /// then decimates at that phase for symbol decisions.
    ///
    /// # Arguments
    /// * `samples` - Audio samples as i16
    ///
    /// # Returns
    /// Symbol indices (0 to constellation.order()-1)
    pub fn demodulate(&mut self, samples: &[i16]) -> Vec<u8> {
        if samples.is_empty() {
            return Vec::new();
        }

        let soft = self.demodulate_to_iq(samples);
        
        soft.iq
            .iter()
            .map(|&(i, q)| self.constellation.iq_to_symbol(i, q))
            .collect()
    }

    /// Demodulate with known timing offset (no timing search)
    ///
    /// Use this when timing is already synchronized (e.g., from preamble).
    pub fn demodulate_with_timing(&mut self, samples: &[i16], timing_offset: usize) -> Vec<u8> {
        if samples.is_empty() {
            return Vec::new();
        }

        let soft = self.demodulate_to_iq_with_timing(samples, timing_offset);
        
        soft.iq
            .iter()
            .map(|&(i, q)| self.constellation.iq_to_symbol(i, q))
            .collect()
    }

    /// Reset demodulator state
    pub fn reset(&mut self) {
        for x in self.i_history.iter_mut() {
            *x = 0.0;
        }
        for x in self.q_history.iter_mut() {
            *x = 0.0;
        }
        self.carrier.reset();
    }

    /// Get reference to constellation
    pub fn constellation(&self) -> &C {
        &self.constellation
    }

    /// Get reference to timing
    pub fn timing(&self) -> &T {
        &self.timing
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::carriers::Nco;
    use crate::constellations::Psk8;
    use crate::modem::Modulator;
    use crate::pulse_shapes::RootRaisedCosine;
    use crate::timing::FixedTiming;

    fn make_modulator() -> Modulator<Psk8, RootRaisedCosine, Nco, FixedTiming> {
        let timing = FixedTiming::new(9600, 2400);
        let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
        let carrier = Nco::new(1800.0, 9600);
        Modulator::new(Psk8, pulse, carrier, timing)
    }

    fn make_demodulator() -> Demodulator<Psk8, RootRaisedCosine, Nco, FixedTiming> {
        let timing = FixedTiming::new(9600, 2400);
        let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
        let carrier = Nco::new(1800.0, 9600);
        Demodulator::new(Psk8, pulse, carrier, timing)
    }

    #[test]
    fn test_loopback() {
        let mut modulator = make_modulator();
        let mut demodulator = make_demodulator();

        // Send some symbols with preamble for timing
        let preamble = vec![0u8; 20]; // Timing acquisition
        let data = vec![0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3];
        let mut all_symbols = preamble.clone();
        all_symbols.extend(&data);

        let samples = modulator.modulate(&all_symbols);
        let flush = modulator.flush();

        let mut all_samples = samples;
        all_samples.extend(flush);

        let recovered = demodulator.demodulate(&all_samples);

        // Skip preamble and filter settling in comparison
        let skip = 20 + 12; // preamble + 2*span
        let data_len = data.len();

        if recovered.len() > skip + data_len {
            let recovered_data = &recovered[skip..skip + data_len];
            assert_eq!(
                recovered_data, &data[..],
                "Loopback failed: {:?} vs {:?}",
                recovered_data, data
            );
        }
    }

    #[test]
    fn test_demodulate_to_iq() {
        let mut modulator = make_modulator();
        let mut demodulator = make_demodulator();

        let symbols = vec![0, 2, 4, 6]; // 0°, 90°, 180°, 270°
        let samples = modulator.modulate(&symbols);
        let flush = modulator.flush();

        let mut all_samples = samples;
        all_samples.extend(flush);

        let soft = demodulator.demodulate_to_iq(&all_samples);

        // Should have roughly the same number of I/Q samples as symbols
        // (plus some from filter settling)
        assert!(soft.iq.len() >= symbols.len(), 
            "Expected at least {} I/Q samples, got {}", 
            symbols.len(), soft.iq.len());

        // Timing offset should be valid
        let sps = 9600 / 2400; // 4
        assert!(soft.timing_offset < sps,
            "Timing offset {} should be < {}", soft.timing_offset, sps);
    }

    #[test]
    fn test_demodulator_reset() {
        let mut demod = make_demodulator();
        
        // Process some samples
        let samples: Vec<i16> = (0..100).map(|i| (i * 100) as i16).collect();
        let _ = demod.demodulate(&samples);

        demod.reset();

        // History should be zeroed
        for &x in demod.i_history.iter() {
            assert_eq!(x, 0.0);
        }
    }
}