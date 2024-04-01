//! Fixed symbol timing
//!
//! Simple deterministic decimation for known symbol rate.
//! No timing recovery - relies on preamble-based synchronization
//! handled at the protocol layer.

use crate::traits::SymbolTiming;

/// Fixed symbol timing (deterministic decimation)
#[derive(Debug, Clone, Copy)]
pub struct FixedTiming {
    sample_rate: u32,
    symbol_rate: u32,
    samples_per_symbol: usize,
}

impl FixedTiming {
    /// Create fixed timing from sample and symbol rates
    ///
    /// # Arguments
    /// * `sample_rate` - Sample rate in Hz
    /// * `symbol_rate` - Symbol rate in baud
    ///
    /// # Panics
    /// Panics if sample_rate is not an integer multiple of symbol_rate
    pub fn new(sample_rate: u32, symbol_rate: u32) -> Self {
        assert!(
            sample_rate % symbol_rate == 0,
            "Sample rate {} must be integer multiple of symbol rate {}",
            sample_rate,
            symbol_rate
        );

        Self {
            sample_rate,
            symbol_rate,
            samples_per_symbol: (sample_rate / symbol_rate) as usize,
        }
    }

    /// Create with default 2400 baud symbol rate
    pub fn default_for_sample_rate(sample_rate: u32) -> Self {
        Self::new(sample_rate, super::DEFAULT_SYMBOL_RATE)
    }
}

impl SymbolTiming for FixedTiming {
    fn samples_per_symbol(&self) -> usize {
        self.samples_per_symbol
    }

    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    fn symbol_rate(&self) -> u32 {
        self.symbol_rate
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[should_panic(expected = "must be integer multiple")]
    fn test_fixed_timing_8000_2400() {
        // 8000 / 2400 = 3.333... - not an integer multiple, should panic
        let _ = FixedTiming::new(8000, 2400);
    }

    #[test]
    fn test_fixed_timing_9600_2400() {
        let timing = FixedTiming::new(9600, 2400);
        assert_eq!(timing.samples_per_symbol(), 4);
        assert_eq!(timing.sample_rate(), 9600);
        assert_eq!(timing.symbol_rate(), 2400);
    }

    #[test]
    fn test_fixed_timing_48000_2400() {
        let timing = FixedTiming::new(48000, 2400);
        assert_eq!(timing.samples_per_symbol(), 20);
    }

    #[test]
    #[should_panic]
    fn test_fixed_timing_non_integer() {
        // 8000 / 2400 = 3.333... not integer
        let _ = FixedTiming::new(8000, 2400);
    }

    #[test]
    fn test_impulse_offset() {
        let timing = FixedTiming::new(9600, 2400);
        assert_eq!(timing.impulse_offset(), 2); // 4/2 = 2
    }
}