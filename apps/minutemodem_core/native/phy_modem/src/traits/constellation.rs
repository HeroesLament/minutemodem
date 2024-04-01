//! Constellation trait - Symbol ↔ I/Q mapping
//!
//! Defines how symbol indices map to complex baseband points.
//! This trait knows nothing about scrambling, framing, or coding.

/// Symbol alphabet mapping trait
///
/// Implementations define the geometry of the constellation diagram.
/// Used by both modulator (symbol → I/Q) and demodulator (I/Q → symbol).
pub trait Constellation: Send + Sync {
    /// Number of points in the constellation (2 for BPSK, 4 for QPSK, etc.)
    fn order(&self) -> usize;

    /// Bits per symbol (log2 of order)
    fn bits_per_symbol(&self) -> usize {
        (self.order() as f64).log2() as usize
    }

    /// Map a symbol index to I/Q coordinates
    ///
    /// # Arguments
    /// * `sym` - Symbol index (0 to order-1)
    ///
    /// # Returns
    /// Tuple of (I, Q) coordinates, normalized to unit circle/square
    fn symbol_to_iq(&self, sym: u8) -> (f64, f64);

    /// Decide the nearest symbol from I/Q coordinates (hard decision)
    ///
    /// # Arguments
    /// * `i` - In-phase component
    /// * `q` - Quadrature component
    ///
    /// # Returns
    /// Symbol index (0 to order-1)
    fn iq_to_symbol(&self, i: f64, q: f64) -> u8;
}