//! Numerically Controlled Oscillator (NCO)
//!
//! Generates carrier signal for modulation and demodulation.
//! Phase-continuous, frequency-adjustable.

use crate::traits::Carrier;
use std::f64::consts::PI;

/// Numerically Controlled Oscillator
#[derive(Debug, Clone)]
pub struct Nco {
    phase: f64,
    phase_inc: f64,
    freq_hz: f64,
    sample_rate: f64,
}

impl Nco {
    /// Create a new NCO
    ///
    /// # Arguments
    /// * `freq_hz` - Carrier frequency in Hz
    /// * `sample_rate` - Sample rate in Hz
    pub fn new(freq_hz: f64, sample_rate: u32) -> Self {
        let sample_rate_f = sample_rate as f64;
        Self {
            phase: 0.0,
            phase_inc: 2.0 * PI * freq_hz / sample_rate_f,
            freq_hz,
            sample_rate: sample_rate_f,
        }
    }

    /// Create NCO at default carrier frequency (1800 Hz)
    pub fn default_for_sample_rate(sample_rate: u32) -> Self {
        Self::new(super::DEFAULT_CARRIER_FREQ, sample_rate)
    }
}

impl Carrier for Nco {
    fn next(&mut self) -> (f64, f64) {
        let (sin, cos) = self.phase.sin_cos();
        self.phase += self.phase_inc;
        
        // Keep phase in [0, 2π) for numerical stability
        if self.phase >= 2.0 * PI {
            self.phase -= 2.0 * PI;
        }
        
        (cos, sin)
    }

    fn reset(&mut self) {
        self.phase = 0.0;
    }

    fn phase(&self) -> f64 {
        self.phase
    }

    fn frequency(&self) -> f64 {
        self.freq_hz
    }

    fn set_frequency(&mut self, freq_hz: f64) {
        self.freq_hz = freq_hz;
        self.phase_inc = 2.0 * PI * freq_hz / self.sample_rate;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_nco_frequency() {
        let nco = Nco::new(1800.0, 8000);
        assert_eq!(nco.frequency(), 1800.0);
    }

    #[test]
    fn test_nco_reset() {
        let mut nco = Nco::new(1800.0, 8000);
        
        // Advance a few samples
        for _ in 0..100 {
            nco.next();
        }
        assert!(nco.phase() > 0.0);
        
        nco.reset();
        assert_eq!(nco.phase(), 0.0);
    }

    #[test]
    fn test_nco_unit_amplitude() {
        let mut nco = Nco::new(1800.0, 8000);
        
        for _ in 0..1000 {
            let (cos, sin) = nco.next();
            let mag = (cos * cos + sin * sin).sqrt();
            assert!(
                (mag - 1.0).abs() < 1e-10,
                "NCO magnitude: {}",
                mag
            );
        }
    }

    #[test]
    fn test_nco_phase_wrapping() {
        let mut nco = Nco::new(1800.0, 8000);
        
        // Run for many samples
        for _ in 0..100000 {
            nco.next();
        }
        
        // Phase should remain bounded
        assert!(nco.phase() >= 0.0 && nco.phase() < 2.0 * PI);
    }
}