//! Carrier oscillator implementations
//!
//! Currently only NCO (Numerically Controlled Oscillator).

mod nco;

pub use nco::Nco;

/// Default carrier frequency for 3kHz channel (center)
pub const DEFAULT_CARRIER_FREQ: f64 = 1800.0;