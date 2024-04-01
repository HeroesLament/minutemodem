//! Core DSP traits for the PHY engine
//!
//! These traits define mathematical behavior, not standards or waveforms.
//! Each trait represents one orthogonal axis of modem configuration.

mod constellation;
mod pulse_shape;
mod carrier;
mod timing;

pub use constellation::Constellation;
pub use pulse_shape::PulseShape;
pub use carrier::Carrier;
pub use timing::SymbolTiming;