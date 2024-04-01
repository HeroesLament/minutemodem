//! Core modem implementations
//!
//! Generic Modulator and Demodulator that compose traits for
//! compile-time specialization.
//!
//! Also includes UnifiedModulator/UnifiedDemodulator for runtime
//! constellation switching (required for 110D mixed PSK8/QAM frames).

mod modulator;
mod demodulator;
mod unified;

pub use modulator::Modulator;
pub use demodulator::Demodulator;
pub use unified::{UnifiedModulator, UnifiedDemodulator, ConstellationType, DFEConfig, DFE, Complex, EqMode};