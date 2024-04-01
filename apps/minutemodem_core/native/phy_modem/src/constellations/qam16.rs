//! 16-QAM constellation per MIL-STD-188-110D Table D-VII
//!
//! This is NOT a standard rectangular 16-QAM constellation.
//! The 110D spec uses a specific rotated/circular arrangement.

use crate::traits::Constellation;

/// 16-QAM constellation per MIL-STD-188-110D Table D-VII
#[derive(Debug, Clone, Copy, Default)]
pub struct Qam16;

/// MIL-STD-188-110D Table D-VII constellation points
/// Symbol Number -> (In-Phase, Quadrature)
const CONSTELLATION: [(f64, f64); 16] = [
    ( 0.866025,  0.500000),  // Symbol 0
    ( 1.000000,  0.000000),  // Symbol 1
    ( 0.500000,  0.866025),  // Symbol 2
    ( 0.258819,  0.258819),  // Symbol 3
    (-0.500000,  0.866025),  // Symbol 4
    ( 0.000000,  1.000000),  // Symbol 5
    (-0.866025,  0.500000),  // Symbol 6
    (-0.258819,  0.258819),  // Symbol 7
    ( 0.500000, -0.866025),  // Symbol 8
    ( 0.000000, -1.000000),  // Symbol 9
    ( 0.866025, -0.500000),  // Symbol 10
    ( 0.258819, -0.258819),  // Symbol 11
    (-0.866025, -0.500000),  // Symbol 12
    (-0.500000, -0.866025),  // Symbol 13
    (-1.000000,  0.000000),  // Symbol 14
    (-0.258819, -0.258819),  // Symbol 15
];

impl Constellation for Qam16 {
    fn order(&self) -> usize {
        16
    }

    fn symbol_to_iq(&self, sym: u8) -> (f64, f64) {
        CONSTELLATION[(sym & 0x0F) as usize]
    }

    fn iq_to_symbol(&self, i: f64, q: f64) -> u8 {
        // Find nearest constellation point using minimum Euclidean distance
        let mut best_sym = 0u8;
        let mut best_dist = f64::MAX;
        
        for (sym, &(ci, cq)) in CONSTELLATION.iter().enumerate() {
            let di = i - ci;
            let dq = q - cq;
            let dist = di * di + dq * dq;
            if dist < best_dist {
                best_dist = dist;
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
    fn test_qam16_roundtrip() {
        let qam = Qam16;
        for sym in 0..16u8 {
            let (i, q) = qam.symbol_to_iq(sym);
            let recovered = qam.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "Symbol {} roundtrip failed", sym);
        }
    }

    #[test]
    fn test_qam16_constellation_values() {
        let qam = Qam16;
        
        // Verify some key points from Table D-VII
        let (i, q) = qam.symbol_to_iq(0);
        assert!((i - 0.866025).abs() < 1e-5);
        assert!((q - 0.500000).abs() < 1e-5);
        
        let (i, q) = qam.symbol_to_iq(1);
        assert!((i - 1.000000).abs() < 1e-5);
        assert!((q - 0.000000).abs() < 1e-5);
        
        let (i, q) = qam.symbol_to_iq(5);
        assert!((i - 0.000000).abs() < 1e-5);
        assert!((q - 1.000000).abs() < 1e-5);
        
        let (i, q) = qam.symbol_to_iq(14);
        assert!((i - (-1.000000)).abs() < 1e-5);
        assert!((q - 0.000000).abs() < 1e-5);
    }

    #[test]
    fn test_qam16_order() {
        assert_eq!(Qam16.order(), 16);
        assert_eq!(Qam16.bits_per_symbol(), 4);
    }
    
    #[test]
    fn test_qam16_slicer_noise_tolerance() {
        let qam = Qam16;
        
        // Test that small noise doesn't change the decision
        for sym in 0..16u8 {
            let (i, q) = qam.symbol_to_iq(sym);
            
            // Add small noise
            let noisy_i = i + 0.05;
            let noisy_q = q - 0.03;
            
            let recovered = qam.iq_to_symbol(noisy_i, noisy_q);
            assert_eq!(sym, recovered, "Symbol {} failed with small noise", sym);
        }
    }
}