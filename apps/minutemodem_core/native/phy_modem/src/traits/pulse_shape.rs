//! PulseShape trait - Spectral shaping / ISI control
//!
//! Defines the pulse shaping filter used for bandwidth limiting.
//! The same filter is used for TX (pulse shaping) and RX (matched filtering).

/// Pulse shaping filter trait
///
/// Implementations provide the filter coefficients and convolution logic.
/// Typically Root Raised Cosine (RRC) for HF modems.
pub trait PulseShape: Send + Sync {
    /// Length of the filter in samples
    fn filter_len(&self) -> usize;

    /// Get the filter coefficients
    fn coefficients(&self) -> &[f64];

    /// Apply the filter to a history buffer (convolution)
    ///
    /// # Arguments
    /// * `history` - Sample history buffer (length must equal filter_len)
    ///
    /// # Returns
    /// Filtered output sample
    fn filter(&self, history: &[f64]) -> f64 {
        debug_assert_eq!(history.len(), self.filter_len());
        self.coefficients()
            .iter()
            .zip(history.iter())
            .map(|(c, h)| c * h)
            .sum()
    }

    /// Filter span in symbols (each side of center)
    fn span_symbols(&self) -> usize;
}