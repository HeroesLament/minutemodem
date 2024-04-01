//! Symbol timing implementations
//!
//! Currently only fixed timing (deterministic decimation).

mod fixed;

pub use fixed::FixedTiming;

/// Default symbol rate for ALE 4G
pub const DEFAULT_SYMBOL_RATE: u32 = 2400;