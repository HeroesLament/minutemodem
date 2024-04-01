//! Pulse shaping filter implementations
//!
//! Currently only Root Raised Cosine (RRC), which is used by
//! both 188-110D and 188-141D with α=0.35.

mod rrc;

pub use rrc::RootRaisedCosine;

/// Default roll-off factor for HF modems
pub const DEFAULT_ALPHA: f64 = 0.35;

/// Default filter span in symbols (each side)
pub const DEFAULT_SPAN: usize = 6;