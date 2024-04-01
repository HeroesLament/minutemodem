//! 8-PSK constellation (3 bits per symbol)
//!
//! Natural mapping (not Gray coded for 141D compatibility):
//! Symbol 0 → 0°
//! Symbol 1 → 45°
//! Symbol 2 → 90°
//! Symbol 3 → 135°
//! Symbol 4 → 180°
//! Symbol 5 → 225°
//! Symbol 6 → 270°
//! Symbol 7 → 315°

use crate::traits::Constellation;
use std::f64::consts::PI;

/// 8-Phase Shift Keying constellation
#[derive(Debug, Clone, Copy, Default)]
pub struct Psk8;

impl Constellation for Psk8 {
    fn order(&self) -> usize {
        8
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        let phase = (sym & 0x07) as f64 * PI / 4.0;
        (phase.cos(), phase.sin())
    }

    fn iq_to_symbol(&self, i: f64, q: f64) -> u8 {
        let angle = q.atan2(i);
        let angle_pos = if angle < 0.0 { angle + 2.0 * PI } else { angle };
        // Add half-sector offset for rounding to nearest
        let symbol = ((angle_pos + PI / 8.0) / (PI / 4.0)).floor() as u8;
        symbol & 0x07
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_psk8_roundtrip() {
        let psk8 = Psk8;
        for sym in 0..8u8 {
            let (i, q) = psk8.symbol_to_iq(sym);
            let recovered = psk8.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_psk8_unit_power() {
        let psk8 = Psk8;
        for sym in 0..8u8 {
            let (i, q) = psk8.symbol_to_iq(sym);
            let power = i * i + q * q;
            assert!((power - 1.0).abs() < 1e-10, "Symbol {} power: {}", sym, power);
        }
    }

    #[test]
    fn test_psk8_phases() {
        let psk8 = Psk8;
        
        // Symbol 0 should be at 0° (I=1, Q=0)
        let (i, q) = psk8.symbol_to_iq(0);
        assert!((i - 1.0).abs() < 1e-10);
        assert!(q.abs() < 1e-10);
        
        // Symbol 2 should be at 90° (I=0, Q=1)
        let (i, q) = psk8.symbol_to_iq(2);
        assert!(i.abs() < 1e-10);
        assert!((q - 1.0).abs() < 1e-10);
        
        // Symbol 4 should be at 180° (I=-1, Q=0)
        let (i, q) = psk8.symbol_to_iq(4);
        assert!((i + 1.0).abs() < 1e-10);
        assert!(q.abs() < 1e-10);
    }

    #[test]
    fn test_psk8_order() {
        assert_eq!(Psk8.order(), 8);
        assert_eq!(Psk8.bits_per_symbol(), 3);
    }
}