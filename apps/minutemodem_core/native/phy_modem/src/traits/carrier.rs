//! Carrier trait - Frequency/phase generation
//!
//! Defines the local oscillator behavior for up/down conversion.
//! Pure physics - no modulation awareness.

/// Carrier oscillator trait
///
/// Implementations generate the carrier signal for modulation/demodulation.
/// Typically a Numerically Controlled Oscillator (NCO).
pub trait Carrier: Send + Sync {
    /// Get the next (cos, sin) sample and advance phase
    ///
    /// # Returns
    /// Tuple of (cos(phase), sin(phase))
    fn next(&mut self) -> (f64, f64);

    /// Reset the oscillator phase to zero
    fn reset(&mut self);

    /// Get the current phase (radians)
    fn phase(&self) -> f64;

    /// Get the carrier frequency in Hz
    fn frequency(&self) -> f64;

    /// Adjust frequency (for AFC if needed later)
    fn set_frequency(&mut self, freq_hz: f64);
}