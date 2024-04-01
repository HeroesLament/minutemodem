//! 64-QAM constellation (6 bits per symbol)
//!
//! Gray-coded 8x8 grid normalized to average unit power.
//! Points at ±1, ±3, ±5, ±7 scaled by 1/√42 for unit average power.

use crate::traits::Constellation;

/// 64-Quadrature Amplitude Modulation constellation
#[derive(Debug, Clone, Copy, Default)]
pub struct Qam64;

// Normalization factor for unit average power: 1/√42
const NORM: f64 = 0.154303349962092; // 1/sqrt(42)

// Gray-coded levels for 3 bits: 000→-7, 001→-5, 011→-3, 010→-1, 110→+1, 111→+3, 101→+5, 100→+7
const LEVELS: [f64; 8] = [-7.0, -5.0, -3.0, -1.0, 1.0, 3.0, 5.0, 7.0];

impl Constellation for Qam64 {
    fn order(&self) -> usize {
        64
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        // Bits: b5 b4 b3 b2 b1 b0
        // I determined by b5 b4 b3 (Gray coded)
        // Q determined by b2 b1 b0 (Gray coded)
        let i_idx = gray3_to_index((sym >> 3) & 0x07);
        let q_idx = gray3_to_index(sym & 0x07);
        
        (LEVELS[i_idx] * NORM, LEVELS[q_idx] * NORM)
    }

    fn iq_to_symbol(&self, i: f64, q: f64) -> u8 {
        let i_idx = level_to_index(i / NORM);
        let q_idx = level_to_index(q / NORM);
        
        (index_to_gray3(i_idx) << 3) | index_to_gray3(q_idx)
    }
}

/// Convert 3-bit Gray code to index (0-7)
fn gray3_to_index(gray: u8) -> usize {
    match gray & 0x07 {
        0b000 => 0, // -7
        0b001 => 1, // -5
        0b011 => 2, // -3
        0b010 => 3, // -1
        0b110 => 4, // +1
        0b111 => 5, // +3
        0b101 => 6, // +5
        0b100 => 7, // +7
        _ => unreachable!(),
    }
}

/// Convert index (0-7) to 3-bit Gray code
fn index_to_gray3(idx: usize) -> u8 {
    match idx {
        0 => 0b000,
        1 => 0b001,
        2 => 0b011,
        3 => 0b010,
        4 => 0b110,
        5 => 0b111,
        6 => 0b101,
        7 => 0b100,
        _ => 0b000,
    }
}

/// Decide which level index is nearest
fn level_to_index(val: f64) -> usize {
    if val < -6.0 {
        0
    } else if val < -4.0 {
        1
    } else if val < -2.0 {
        2
    } else if val < 0.0 {
        3
    } else if val < 2.0 {
        4
    } else if val < 4.0 {
        5
    } else if val < 6.0 {
        6
    } else {
        7
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_qam64_roundtrip() {
        let qam = Qam64;
        for sym in 0..64u8 {
            let (i, q) = qam.symbol_to_iq(sym);
            let recovered = qam.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_qam64_average_power() {
        let qam = Qam64;
        let mut total_power = 0.0;
        for sym in 0..64u8 {
            let (i, q) = qam.symbol_to_iq(sym);
            total_power += i * i + q * q;
        }
        let avg_power = total_power / 64.0;
        assert!((avg_power - 1.0).abs() < 1e-10, "Average power: {}", avg_power);
    }

    #[test]
    fn test_qam64_order() {
        assert_eq!(Qam64.order(), 64);
        assert_eq!(Qam64.bits_per_symbol(), 6);
    }
}