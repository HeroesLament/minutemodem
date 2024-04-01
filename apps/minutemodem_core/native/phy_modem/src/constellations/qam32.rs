//! 32-QAM constellation (5 bits per symbol)
//!
//! Cross constellation (not square) - 32 points arranged in a cross pattern.
//! This is the standard 32-QAM for HF modems per MIL-STD-188-110D.

use crate::traits::Constellation;

/// 32-Quadrature Amplitude Modulation constellation (cross)
#[derive(Debug, Clone, Copy, Default)]
pub struct Qam32;

// Normalization factor for unit average power
// For cross-32QAM, average power = 20 (unnormalized), so norm = 1/√20
const NORM: f64 = 0.223606797749979; // 1/sqrt(20)

// 32-QAM cross constellation points (I, Q) before normalization
// Arranged as a cross: inner 4x4 square with 4 corner extensions
const QAM32_MAP: [(i8, i8); 32] = [
    // Inner 4x4 (16 points)
    (-3, -1), (-3, 1), (-1, -3), (-1, -1),
    (-1, 1), (-1, 3), (1, -3), (1, -1),
    (1, 1), (1, 3), (3, -1), (3, 1),
    // Outer ring extensions (20 more points for cross shape)
    (-5, -1), (-5, 1), (-3, -3), (-3, 3),
    (-1, -5), (-1, 5), (1, -5), (1, 5),
    (3, -3), (3, 3), (5, -1), (5, 1),
    // Additional corner fills
    (-5, -3), (-5, 3), (-3, -5), (-3, 5),
    (3, -5), (3, 5), (5, -3), (5, 3),
];

impl Constellation for Qam32 {
    fn order(&self) -> usize {
        32
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        let idx = (sym & 0x1F) as usize;
        let (i, q) = QAM32_MAP[idx];
        (i as f64 * NORM, q as f64 * NORM)
    }

    fn iq_to_symbol(&self, i: f64, q: f64) -> u8 {
        // Denormalize
        let i_val = i / NORM;
        let q_val = q / NORM;
        
        // Find nearest constellation point
        let mut min_dist = f64::MAX;
        let mut best_sym = 0u8;
        
        for (sym, &(ci, cq)) in QAM32_MAP.iter().enumerate() {
            let di = i_val - ci as f64;
            let dq = q_val - cq as f64;
            let dist = di * di + dq * dq;
            if dist < min_dist {
                min_dist = dist;
                best_sym = sym as u8;
            }
        }
        
        best_sym
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_qam32_roundtrip() {
        let qam = Qam32;
        for sym in 0..32u8 {
            let (i, q) = qam.symbol_to_iq(sym);
            let recovered = qam.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_qam32_order() {
        assert_eq!(Qam32.order(), 32);
        assert_eq!(Qam32.bits_per_symbol(), 5);
    }
}