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

#[cfg(test)]
mod unified_modem_tests;

pub use modulator::Modulator;
pub use demodulator::Demodulator;
pub use unified::{UnifiedModulator, UnifiedDemodulator, ConstellationType, DFEConfig, DFE, Complex, EqMode, PllTelemetry, DfeTelemetry};

pub mod walsh;
pub use walsh::WalshCorrelator;

pub mod turbo;
pub use turbo::{turbo_decode, BcjrDecoder};
pub(crate) use unified::{generate_rrc_coeffs, RRC_SPAN};