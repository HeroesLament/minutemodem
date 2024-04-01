//! BPSK constellation (1 bit per symbol)
//!
//! Symbol 0 → +1 (0°)
//! Symbol 1 → -1 (180°)

use crate::traits::Constellation;

/// Binary Phase Shift Keying constellation
#[derive(Debug, Clone, Copy, Default)]
pub struct Bpsk;

impl Constellation for Bpsk {
    fn order(&self) -> usize {
        2
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        match sym & 0x01 {
            0 => (1.0, 0.0),
            _ => (-1.0, 0.0),
        }
    }

    fn iq_to_symbol(&self, i: f64, _q: f64) -> u8 {
        if i >= 0.0 { 0 } else { 1 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bpsk_roundtrip() {
        let bpsk = Bpsk;
        for sym in 0..2u8 {
            let (i, q) = bpsk.symbol_to_iq(sym);
            let recovered = bpsk.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_bpsk_order() {
        assert_eq!(Bpsk.order(), 2);
        assert_eq!(Bpsk.bits_per_symbol(), 1);
    }
}