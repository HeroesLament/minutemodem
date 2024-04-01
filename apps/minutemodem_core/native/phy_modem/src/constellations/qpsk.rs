//! QPSK constellation (2 bits per symbol)
//!
//! Gray-coded mapping:
//! Symbol 0 → 45°  (I=+1, Q=+1) / √2
//! Symbol 1 → 135° (I=-1, Q=+1) / √2
//! Symbol 2 → 315° (I=+1, Q=-1) / √2
//! Symbol 3 → 225° (I=-1, Q=-1) / √2

use crate::traits::Constellation;
use std::f64::consts::FRAC_1_SQRT_2;

/// Quadrature Phase Shift Keying constellation (Gray coded)
#[derive(Debug, Clone, Copy, Default)]
pub struct Qpsk;

impl Constellation for Qpsk {
    fn order(&self) -> usize {
        4
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        // Gray coding: 00→45°, 01→135°, 11→225°, 10→315°
        let i = if (sym & 0x02) == 0 { FRAC_1_SQRT_2 } else { -FRAC_1_SQRT_2 };
        let q = if (sym & 0x01) == 0 { FRAC_1_SQRT_2 } else { -FRAC_1_SQRT_2 };
        (i, q)
    }

    fn iq_to_symbol(&self, i: f64, q: f64) -> u8 {
        let mut sym = 0u8;
        if i < 0.0 { sym |= 0x02; }
        if q < 0.0 { sym |= 0x01; }
        sym
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_qpsk_roundtrip() {
        let qpsk = Qpsk;
        for sym in 0..4u8 {
            let (i, q) = qpsk.symbol_to_iq(sym);
            let recovered = qpsk.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_qpsk_unit_power() {
        let qpsk = Qpsk;
        for sym in 0..4u8 {
            let (i, q) = qpsk.symbol_to_iq(sym);
            let power = i * i + q * q;
            assert!((power - 1.0).abs() < 1e-10, "Symbol {} power: {}", sym, power);
        }
    }

    #[test]
    fn test_qpsk_order() {
        assert_eq!(Qpsk.order(), 4);
        assert_eq!(Qpsk.bits_per_symbol(), 2);
    }
}