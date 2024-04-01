//! Generic Modulator
//!
//! Composes Constellation, PulseShape, Carrier, and SymbolTiming traits
//! into a unified modulation engine. No runtime branching on modulation type.

use crate::traits::{Carrier, Constellation, PulseShape, SymbolTiming};

/// Generic modulator composed of trait implementations
///
/// # Type Parameters
/// * `C` - Constellation (symbol → I/Q mapping)
/// * `P` - Pulse shape (spectral shaping)
/// * `K` - Carrier (NCO)
/// * `T` - Symbol timing (samples per symbol)
pub struct Modulator<C, P, K, T>
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
    output_scale: f64,
}

impl<C, P, K, T> Modulator<C, P, K, T>
where
    C: Constellation,
    P: PulseShape,
    K: Carrier,
    T: SymbolTiming,
{
    /// Create a new modulator
    ///
    /// # Arguments
    /// * `constellation` - Symbol mapping implementation
    /// * `pulse` - Pulse shaping filter
    /// * `carrier` - Carrier oscillator
    /// * `timing` - Symbol timing
    pub fn new(constellation: C, pulse: P, carrier: K, timing: T) -> Self {
        let filter_len = pulse.filter_len();
        Self {
            constellation,
            pulse,
            carrier,
            timing,
            i_history: vec![0.0; filter_len],
            q_history: vec![0.0; filter_len],
            // Scale for unity matched filter gain after RX processing:
            // RX: /32768 * 2.0 * RRC_gain
            // Empirically calibrated for I/Q unity at symbol centers
            output_scale: 32768.0,
        }
    }

    /// Set output scale factor (default 24000)
    pub fn set_output_scale(&mut self, scale: f64) {
        self.output_scale = scale;
    }

    /// Modulate symbols to audio samples
    ///
    /// # Arguments
    /// * `symbols` - Symbol indices (0 to constellation.order()-1)
    ///
    /// # Returns
    /// Audio samples as i16 (signed 16-bit)
    pub fn modulate(&mut self, symbols: &[u8]) -> Vec<i16> {
        let sps = self.timing.samples_per_symbol();
        let impulse_offset = self.timing.impulse_offset();
        let mut output = Vec::with_capacity(symbols.len() * sps);

        for &sym in symbols {
            // Map symbol to I/Q
            let (i_val, q_val) = self.constellation.symbol_to_iq(sym);

            // Generate samples for this symbol period
            for sample_idx in 0..sps {
                // Shift history (rotate left, add at end)
                self.i_history.rotate_left(1);
                self.q_history.rotate_left(1);

                let last = self.i_history.len() - 1;

                // Insert impulse at symbol center, zero elsewhere
                if sample_idx == impulse_offset {
                    self.i_history[last] = i_val;
                    self.q_history[last] = q_val;
                } else {
                    self.i_history[last] = 0.0;
                    self.q_history[last] = 0.0;
                }

                // Apply pulse shaping filter
                let i_filtered = self.pulse.filter(&self.i_history);
                let q_filtered = self.pulse.filter(&self.q_history);

                // Modulate onto carrier
                let (cos, sin) = self.carrier.next();
                let sample = i_filtered * cos - q_filtered * sin;

                // Scale and convert to i16
                output.push((sample * self.output_scale) as i16);
            }
        }

        output
    }

    /// Flush the filter with zeros to get the tail
    ///
    /// Should be called at end of transmission to drain the filter.
    pub fn flush(&mut self) -> Vec<i16> {
        // Need 2 * span symbols to fully flush TX and allow RX to flush
        let flush_count = 2 * self.pulse.span_symbols();
        let zeros = vec![0u8; flush_count];
        self.modulate(&zeros)
    }

    /// Reset modulator state
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
    use crate::pulse_shapes::RootRaisedCosine;
    use crate::timing::FixedTiming;

    fn make_test_modulator() -> Modulator<Psk8, RootRaisedCosine, Nco, FixedTiming> {
        let timing = FixedTiming::new(9600, 2400);
        let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
        let carrier = Nco::new(1800.0, 9600);
        Modulator::new(Psk8, pulse, carrier, timing)
    }

    #[test]
    fn test_modulator_output_length() {
        let mut mod_ = make_test_modulator();
        let symbols = vec![0, 1, 2, 3, 4, 5, 6, 7];
        let samples = mod_.modulate(&symbols);

        // 8 symbols * 4 samples/symbol = 32 samples
        assert_eq!(samples.len(), 32);
    }

    #[test]
    fn test_modulator_reset() {
        let mut mod_ = make_test_modulator();
        let symbols = vec![0, 1, 2, 3];
        let _ = mod_.modulate(&symbols);

        mod_.reset();

        // History should be zeroed
        for &x in mod_.i_history.iter() {
            assert_eq!(x, 0.0);
        }
    }

    #[test]
    fn test_modulator_determinism() {
        let mut mod1 = make_test_modulator();
        let mut mod2 = make_test_modulator();

        let symbols = vec![0, 1, 2, 3, 4, 5, 6, 7];
        let samples1 = mod1.modulate(&symbols);
        let samples2 = mod2.modulate(&symbols);

        assert_eq!(samples1, samples2);
    }

    #[test]
    fn test_modulator_bounded_output() {
        let mut mod_ = make_test_modulator();
        let symbols: Vec<u8> = (0..100).map(|i| i % 8).collect();
        let samples = mod_.modulate(&symbols);

        for &s in &samples {
            assert!(
                s.abs() < 32000,
                "Sample {} exceeds safe range",
                s
            );
        }
    }
}