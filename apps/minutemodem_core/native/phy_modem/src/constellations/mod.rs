//! Constellation implementations
//!
//! All Appendix D modulation types live here:
//! - BPSK (1 bit/symbol)
//! - QPSK (2 bits/symbol)
//! - 8-PSK (3 bits/symbol)
//! - 16-QAM (4 bits/symbol)
//! - 32-QAM (5 bits/symbol)
//! - 64-QAM (6 bits/symbol)

mod bpsk;
mod qpsk;
mod psk8;
mod qam16;
mod qam32;
mod qam64;

pub use bpsk::Bpsk;
pub use qpsk::Qpsk;
pub use psk8::Psk8;
pub use qam16::Qam16;
pub use qam32::Qam32;
pub use qam64::Qam64;