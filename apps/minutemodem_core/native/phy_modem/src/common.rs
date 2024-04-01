//! Shared DSP components for 8-PSK modem

use std::f64::consts::PI;

/// 8-PSK phase mapping (radians)
/// Symbol 0 = 0°, Symbol 1 = 45°, etc.
pub const PSK8_PHASES: [f64; 8] = [
    0.0,              // 0: 0°
    PI / 4.0,         // 1: 45°
    PI / 2.0,         // 2: 90°
    3.0 * PI / 4.0,   // 3: 135°
    PI,               // 4: 180°
    5.0 * PI / 4.0,   // 5: 225°
    3.0 * PI / 2.0,   // 6: 270°
    7.0 * PI / 4.0,   // 7: 315°
];

/// RRC filter parameters
pub const RRC_ALPHA: f64 = 0.35;  // Roll-off factor (excess bandwidth)
pub const RRC_SPAN: usize = 6;     // Filter span in symbols (each side)

/// Default carrier frequency (center of 3kHz channel)
pub const CARRIER_FREQ: f64 = 1800.0;

/// Symbol rate for ALE 4G
pub const SYMBOL_RATE: u32 = 2400;

/// Generate Root Raised Cosine filter coefficients
pub fn generate_rrc_filter(samples_per_symbol: usize, alpha: f64, span: usize) -> Vec<f64> {
    let filter_len = 2 * span * samples_per_symbol + 1;
    let mut coeffs = Vec::with_capacity(filter_len);
    
    let t_symbol = 1.0; // Normalized symbol period
    
    for i in 0..filter_len {
        let t = (i as f64 - (filter_len - 1) as f64 / 2.0) / samples_per_symbol as f64;
        
        let h = if t.abs() < 1e-10 {
            // t = 0
            (1.0 + alpha * (4.0 / PI - 1.0)) / t_symbol
        } else if (t.abs() - t_symbol / (4.0 * alpha)).abs() < 1e-10 {
            // t = ±T/(4α)
            let term1 = (1.0 + 2.0 / PI) * (PI * alpha / 4.0).sin();
            let term2 = (1.0 - 2.0 / PI) * (PI * alpha / 4.0).cos();
            alpha / (t_symbol * 2.0_f64.sqrt()) * (term1 + term2)
        } else {
            // General case
            let num = (PI * t / t_symbol * (1.0 - alpha)).sin()
                + 4.0 * alpha * t / t_symbol * (PI * t / t_symbol * (1.0 + alpha)).cos();
            let den = PI * t / t_symbol * (1.0 - (4.0 * alpha * t / t_symbol).powi(2));
            num / den / t_symbol
        };
        
        coeffs.push(h);
    }
    
    // Normalize filter energy
    let energy: f64 = coeffs.iter().map(|x| x * x).sum();
    let norm = energy.sqrt();
    for c in &mut coeffs {
        *c /= norm;
    }
    
    coeffs
}