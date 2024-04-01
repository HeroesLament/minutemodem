//! Root Raised Cosine (RRC) pulse shaping filter
//!
//! The standard pulse shape for HF modems. When convolved with itself
//! (TX then RX), produces zero ISI at symbol centers.

use crate::traits::PulseShape;
use std::f64::consts::PI;

/// Root Raised Cosine filter
#[derive(Debug, Clone)]
pub struct RootRaisedCosine {
    coeffs: Vec<f64>,
    span: usize,
    samples_per_symbol: usize,
}

impl RootRaisedCosine {
    /// Create a new RRC filter
    ///
    /// # Arguments
    /// * `samples_per_symbol` - Number of samples per symbol period
    /// * `alpha` - Roll-off factor (excess bandwidth), typically 0.35
    /// * `span` - Filter span in symbols (each side of center)
    pub fn new(samples_per_symbol: usize, alpha: f64, span: usize) -> Self {
        let coeffs = generate_rrc_coefficients(samples_per_symbol, alpha, span);
        Self {
            coeffs,
            span,
            samples_per_symbol,
        }
    }

    /// Create with default parameters (α=0.35, span=6)
    pub fn default_for_sps(samples_per_symbol: usize) -> Self {
        Self::new(samples_per_symbol, super::DEFAULT_ALPHA, super::DEFAULT_SPAN)
    }
}

impl PulseShape for RootRaisedCosine {
    fn filter_len(&self) -> usize {
        self.coeffs.len()
    }

    fn coefficients(&self) -> &[f64] {
        &self.coeffs
    }

    fn span_symbols(&self) -> usize {
        self.span
    }
}

/// Generate RRC filter coefficients
///
/// Implements the standard RRC impulse response formula with
/// proper handling of the singularity points.
fn generate_rrc_coefficients(samples_per_symbol: usize, alpha: f64, span: usize) -> Vec<f64> {
    let filter_len = 2 * span * samples_per_symbol + 1;
    let mut coeffs = Vec::with_capacity(filter_len);

    let t_symbol = 1.0; // Normalized symbol period

    for i in 0..filter_len {
        // t is time in symbol periods, centered at 0
        let t = (i as f64 - (filter_len - 1) as f64 / 2.0) / samples_per_symbol as f64;

        let h = if t.abs() < 1e-10 {
            // t = 0 (center tap)
            (1.0 + alpha * (4.0 / PI - 1.0)) / t_symbol
        } else if (t.abs() - t_symbol / (4.0 * alpha)).abs() < 1e-10 {
            // t = ±T/(4α) (singularity points)
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

    // Normalize filter for unit energy
    let energy: f64 = coeffs.iter().map(|x| x * x).sum();
    let norm = energy.sqrt();
    for c in &mut coeffs {
        *c /= norm;
    }

    coeffs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rrc_filter_length() {
        let rrc = RootRaisedCosine::new(4, 0.35, 6);
        // 2 * 6 * 4 + 1 = 49 taps
        assert_eq!(rrc.filter_len(), 49);
    }

    #[test]
    fn test_rrc_symmetry() {
        let rrc = RootRaisedCosine::new(4, 0.35, 6);
        let coeffs = rrc.coefficients();
        let len = coeffs.len();
        
        // RRC is symmetric
        for i in 0..len / 2 {
            assert!(
                (coeffs[i] - coeffs[len - 1 - i]).abs() < 1e-10,
                "Asymmetric at index {}: {} vs {}",
                i,
                coeffs[i],
                coeffs[len - 1 - i]
            );
        }
    }

    #[test]
    fn test_rrc_unit_energy() {
        let rrc = RootRaisedCosine::new(4, 0.35, 6);
        let energy: f64 = rrc.coefficients().iter().map(|x| x * x).sum();
        assert!(
            (energy - 1.0).abs() < 1e-10,
            "Filter energy: {}",
            energy
        );
    }

    #[test]
    fn test_rrc_center_tap_is_max() {
        let rrc = RootRaisedCosine::new(4, 0.35, 6);
        let coeffs = rrc.coefficients();
        let center = coeffs.len() / 2;
        
        for (i, &c) in coeffs.iter().enumerate() {
            assert!(
                coeffs[center] >= c,
                "Center tap {} at {} is not max, {} at {} is larger",
                coeffs[center],
                center,
                c,
                i
            );
        }
    }
}