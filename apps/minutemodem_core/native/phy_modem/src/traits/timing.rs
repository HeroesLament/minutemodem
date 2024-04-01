//! SymbolTiming trait - Sample/symbol rate relationship
//!
//! Defines how many samples per symbol period.
//! Keeps the door open for future timing recovery algorithms.

/// Symbol timing trait
///
/// Implementations define the relationship between sample rate and symbol rate.
/// Currently fixed decimation, but can be extended for:
/// - Gardner timing recovery
/// - Mueller-Müller
/// - NDA timing recovery
pub trait SymbolTiming: Send + Sync {
    /// Samples per symbol period
    fn samples_per_symbol(&self) -> usize;

    /// Sample rate in Hz
    fn sample_rate(&self) -> u32;

    /// Symbol rate in baud
    fn symbol_rate(&self) -> u32 {
        self.sample_rate() / self.samples_per_symbol() as u32
    }

    /// Sample index within symbol period where impulse is placed (TX)
    /// or where decision is made (RX with fixed timing)
    fn impulse_offset(&self) -> usize {
        self.samples_per_symbol() / 2
    }
}