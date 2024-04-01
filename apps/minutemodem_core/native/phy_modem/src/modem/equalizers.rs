//! Decision Feedback Equalizer (DFE) for HF Multipath Channels
//!
//! This module implements an adaptive DFE suitable for HF skywave channels
//! with delay spreads of 2-4ms. The equalizer uses LMS adaptation and can
//! operate in two modes:
//!
//! 1. **Training Mode**: Uses known symbols (e.g., capture probe) for fast
//!    initial convergence
//! 2. **Decision-Directed Mode**: Uses slicer decisions for tracking
//!
//! ## Architecture
//!
//! ```text
//!                    ┌─────────────────────────────────────────┐
//!                    │                                         │
//! IQ ──►[Feedforward Filter]──►(Σ)──►[Slicer]──►Decisions
//!                    ▲           │         │
//!                    │           │         ▼
//!                    │           │    [Feedback Filter]
//!                    │           │         │
//!                    └───────────┴─────────┘
//!                              LMS Update
//! ```
//!
//! ## References
//!
//! - MIL-STD-188-110D Appendix C (Equalization)
//! - Proakis, "Digital Communications", Chapter 10
//! - Watterson HF Channel Model (CCIR Rep. 549-1)

use std::f64::consts::PI;

use super::modem::ConstellationType;

// ============================================================================
// Complex Number Type
// ============================================================================

/// Simple complex number type (avoids external dependency)
#[derive(Debug, Clone, Copy, Default)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    #[inline]
    pub fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    #[inline]
    pub fn zero() -> Self {
        Self { re: 0.0, im: 0.0 }
    }

    #[inline]
    pub fn conj(self) -> Self {
        Self { re: self.re, im: -self.im }
    }

    #[inline]
    pub fn mag_sq(self) -> f64 {
        self.re * self.re + self.im * self.im
    }

    #[inline]
    pub fn mag(self) -> f64 {
        self.mag_sq().sqrt()
    }

    #[inline]
    pub fn phase(self) -> f64 {
        self.im.atan2(self.re)
    }
}

impl std::ops::Add for Complex {
    type Output = Self;
    #[inline]
    fn add(self, rhs: Self) -> Self {
        Self { re: self.re + rhs.re, im: self.im + rhs.im }
    }
}

impl std::ops::Sub for Complex {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        Self { re: self.re - rhs.re, im: self.im - rhs.im }
    }
}

impl std::ops::Mul for Complex {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self {
        Self {
            re: self.re * rhs.re - self.im * rhs.im,
            im: self.re * rhs.im + self.im * rhs.re,
        }
    }
}

impl std::ops::Mul<f64> for Complex {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: f64) -> Self {
        Self { re: self.re * rhs, im: self.im * rhs }
    }
}

impl std::ops::AddAssign for Complex {
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        self.re += rhs.re;
        self.im += rhs.im;
    }
}

impl std::ops::SubAssign for Complex {
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        self.re -= rhs.re;
        self.im -= rhs.im;
    }
}

impl std::iter::Sum for Complex {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Complex::zero(), |acc, x| acc + x)
    }
}

// ============================================================================
// DFE Configuration
// ============================================================================

/// Configuration for the Decision Feedback Equalizer
#[derive(Debug, Clone)]
pub struct DFEConfig {
    /// Number of feedforward filter taps (typically 11-21)
    /// Should span ±delay_spread in symbols
    pub ff_taps: usize,

    /// Number of feedback filter taps (typically 5-10)
    /// Should match the postcursor ISI span
    pub fb_taps: usize,

    /// LMS step size for coefficient adaptation
    /// Typical: 0.01 (slow/stable) to 0.1 (fast/less stable)
    pub mu: f64,

    /// Leakage factor for coefficient updates (prevents drift)
    /// Typical: 0.9999 to 1.0 (1.0 = no leakage)
    pub leakage: f64,

    /// Minimum signal magnitude to update coefficients
    /// Prevents adaptation on noise/deep fades
    pub update_threshold: f64,
}

impl Default for DFEConfig {
    fn default() -> Self {
        Self {
            ff_taps: 15,           // ±7 symbols (covers ~3ms at 2400 baud)
            fb_taps: 7,            // 7 symbol postcursor span
            mu: 0.03,              // Moderate adaptation speed
            leakage: 0.9999,       // Very slight leakage
            update_threshold: 0.1, // -20dB threshold
        }
    }
}

impl DFEConfig {
    /// Configuration optimized for HF skywave channels
    pub fn hf_skywave() -> Self {
        Self {
            ff_taps: 21,          // ±10 symbols (~4ms at 2400 baud)
            fb_taps: 10,          // Match delay spread
            mu: 0.02,             // Conservative for fading
            leakage: 0.9999,
            update_threshold: 0.15,
        }
    }

    /// Configuration for ground wave (minimal multipath)
    pub fn ground_wave() -> Self {
        Self {
            ff_taps: 7,
            fb_taps: 3,
            mu: 0.05,
            leakage: 1.0,
            update_threshold: 0.05,
        }
    }

    /// Fast acquisition configuration (for training)
    pub fn fast_acquisition() -> Self {
        Self {
            ff_taps: 15,
            fb_taps: 7,
            mu: 0.1,              // Aggressive adaptation
            leakage: 0.999,
            update_threshold: 0.05,
        }
    }
}

// ============================================================================
// Decision Feedback Equalizer
// ============================================================================

/// Decision Feedback Equalizer with LMS adaptation
///
/// Designed for HF channels with multipath (2-4ms delay spread).
/// Uses complex-valued filters for full I/Q equalization.
pub struct DFE {
    // Configuration
    config: DFEConfig,
    constellation: ConstellationType,

    // Feedforward filter
    ff_coeffs: Vec<Complex>,
    ff_history: Vec<Complex>,

    // Feedback filter
    fb_coeffs: Vec<Complex>,
    fb_history: Vec<u8>,

    // Statistics
    total_symbols: u64,
    error_power_avg: f64,
}

impl DFE {
    /// Create a new DFE with the given configuration
    pub fn new(config: DFEConfig, constellation: ConstellationType) -> Self {
        let ff_taps = config.ff_taps;
        let fb_taps = config.fb_taps;

        let mut dfe = Self {
            config,
            constellation,
            ff_coeffs: vec![Complex::zero(); ff_taps],
            ff_history: vec![Complex::zero(); ff_taps],
            fb_coeffs: vec![Complex::zero(); fb_taps],
            fb_history: vec![0; fb_taps],
            total_symbols: 0,
            error_power_avg: 0.0,
        };

        // Initialize center tap to unity gain
        dfe.init_center_tap();

        dfe
    }

    /// Create with default HF skywave configuration
    pub fn new_hf(constellation: ConstellationType) -> Self {
        Self::new(DFEConfig::hf_skywave(), constellation)
    }

    /// Initialize center tap to 1.0 (identity filter)
    fn init_center_tap(&mut self) {
        let center = self.ff_coeffs.len() / 2;
        self.ff_coeffs[center] = Complex::new(1.0, 0.0);
    }

    /// Reset equalizer state (for new transmission)
    pub fn reset(&mut self) {
        for c in &mut self.ff_coeffs {
            *c = Complex::zero();
        }
        for c in &mut self.fb_coeffs {
            *c = Complex::zero();
        }
        for h in &mut self.ff_history {
            *h = Complex::zero();
        }
        for s in &mut self.fb_history {
            *s = 0;
        }

        self.init_center_tap();
        self.total_symbols = 0;
        self.error_power_avg = 0.0;
    }

    /// Get current constellation
    pub fn constellation(&self) -> ConstellationType {
        self.constellation
    }

    /// Set constellation (for mid-frame switching in 110D)
    pub fn set_constellation(&mut self, constellation: ConstellationType) {
        self.constellation = constellation;
    }

    /// Process one I/Q sample in decision-directed mode
    ///
    /// Returns the equalized symbol decision.
    pub fn equalize(&mut self, i: f64, q: f64) -> u8 {
        let input = Complex::new(i, q);

        // Shift input into feedforward history
        self.ff_history.rotate_right(1);
        self.ff_history[0] = input;

        // Compute feedforward filter output
        let ff_out = self.compute_ff_output();

        // Compute feedback filter output (cancels postcursor ISI)
        let fb_out = self.compute_fb_output();

        // Equalized output
        let eq_out = ff_out - fb_out;

        // Make hard decision
        let decision = self.constellation.iq_to_symbol(eq_out.re, eq_out.im);

        // Compute error
        let (dec_i, dec_q) = self.constellation.symbol_to_iq(decision);
        let reference = Complex::new(dec_i, dec_q);
        let error = eq_out - reference;

        // Update coefficients if signal is strong enough
        let sig_power = input.mag_sq();
        if sig_power > self.config.update_threshold {
            self.update_coefficients(error);
        }

        // Update feedback history with decision
        self.fb_history.rotate_right(1);
        self.fb_history[0] = decision;

        // Update statistics
        self.total_symbols += 1;
        let alpha = 0.99;
        self.error_power_avg = alpha * self.error_power_avg + (1.0 - alpha) * error.mag_sq();

        decision
    }

    /// Train on known symbol (faster convergence)
    ///
    /// Use this during known preamble/probe sequences for faster acquisition.
    pub fn train(&mut self, i: f64, q: f64, known_symbol: u8) -> u8 {
        let input = Complex::new(i, q);

        // Shift input into feedforward history
        self.ff_history.rotate_right(1);
        self.ff_history[0] = input;

        // Compute feedforward filter output
        let ff_out = self.compute_ff_output();

        // Compute feedback filter output
        let fb_out = self.compute_fb_output();

        // Equalized output
        let eq_out = ff_out - fb_out;

        // Use KNOWN symbol as reference (not decision)
        let (ref_i, ref_q) = self.constellation.symbol_to_iq(known_symbol);
        let reference = Complex::new(ref_i, ref_q);
        let error = eq_out - reference;

        // Update coefficients (always update during training)
        self.update_coefficients_training(error);

        // Update feedback history with KNOWN symbol
        self.fb_history.rotate_right(1);
        self.fb_history[0] = known_symbol;

        // Update statistics
        self.total_symbols += 1;
        let alpha = 0.99;
        self.error_power_avg = alpha * self.error_power_avg + (1.0 - alpha) * error.mag_sq();

        // Return decision (for monitoring, not used in feedback)
        self.constellation.iq_to_symbol(eq_out.re, eq_out.im)
    }

    /// Equalize a batch of I/Q samples
    pub fn equalize_batch(&mut self, iq_samples: &[(f64, f64)]) -> Vec<u8> {
        iq_samples
            .iter()
            .map(|&(i, q)| self.equalize(i, q))
            .collect()
    }

    /// Train on a batch of known symbols
    pub fn train_batch(&mut self, iq_samples: &[(f64, f64)], known_symbols: &[u8]) -> Vec<u8> {
        iq_samples
            .iter()
            .zip(known_symbols)
            .map(|(&(i, q), &sym)| self.train(i, q, sym))
            .collect()
    }

    /// Get current mean squared error (for monitoring)
    pub fn mse(&self) -> f64 {
        self.error_power_avg
    }

    /// Get total symbols processed
    pub fn symbols_processed(&self) -> u64 {
        self.total_symbols
    }

    /// Get feedforward coefficients (for debugging/visualization)
    pub fn ff_coefficients(&self) -> Vec<(f64, f64)> {
        self.ff_coeffs.iter().map(|c| (c.re, c.im)).collect()
    }

    /// Get feedback coefficients (for debugging/visualization)
    pub fn fb_coefficients(&self) -> Vec<(f64, f64)> {
        self.fb_coeffs.iter().map(|c| (c.re, c.im)).collect()
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    #[inline]
    fn compute_ff_output(&self) -> Complex {
        self.ff_coeffs
            .iter()
            .zip(&self.ff_history)
            .map(|(c, h)| *c * *h)
            .sum()
    }

    #[inline]
    fn compute_fb_output(&self) -> Complex {
        self.fb_coeffs
            .iter()
            .zip(&self.fb_history)
            .map(|(c, &sym)| {
                let (i, q) = self.constellation.symbol_to_iq(sym);
                *c * Complex::new(i, q)
            })
            .sum()
    }

    fn update_coefficients(&mut self, error: Complex) {
        let mu = self.config.mu;
        let leakage = self.config.leakage;

        // Update feedforward coefficients (LMS)
        // W_new = leakage * W_old - mu * error * conj(input)
        for (c, h) in self.ff_coeffs.iter_mut().zip(&self.ff_history) {
            let update = error * h.conj() * mu;
            *c = *c * leakage - update;
        }

        // Update feedback coefficients (LMS)
        // V_new = leakage * V_old + mu * error * conj(past_decision)
        for (c, &sym) in self.fb_coeffs.iter_mut().zip(&self.fb_history) {
            let (i, q) = self.constellation.symbol_to_iq(sym);
            let past = Complex::new(i, q);
            let update = error * past.conj() * mu;
            *c = *c * leakage + update;
        }
    }

    fn update_coefficients_training(&mut self, error: Complex) {
        // Use higher step size during training
        let mu = self.config.mu * 2.0; // 2x faster during training
        let leakage = self.config.leakage;

        for (c, h) in self.ff_coeffs.iter_mut().zip(&self.ff_history) {
            let update = error * h.conj() * mu;
            *c = *c * leakage - update;
        }

        for (c, &sym) in self.fb_coeffs.iter_mut().zip(&self.fb_history) {
            let (i, q) = self.constellation.symbol_to_iq(sym);
            let past = Complex::new(i, q);
            let update = error * past.conj() * mu;
            *c = *c * leakage + update;
        }
    }
}

// ============================================================================
// Fractionally-Spaced Equalizer (Optional Enhancement)
// ============================================================================

/// Fractionally-Spaced Equalizer Configuration
///
/// FSE uses T/2 spaced samples for better timing tolerance.
/// This is an enhancement over the symbol-spaced DFE above.
#[derive(Debug, Clone)]
pub struct FSEConfig {
    /// Samples per symbol (typically 2 for T/2 spacing)
    pub samples_per_symbol: usize,

    /// Number of filter taps (at T/2 spacing)
    pub taps: usize,

    /// LMS step size
    pub mu: f64,
}

impl Default for FSEConfig {
    fn default() -> Self {
        Self {
            samples_per_symbol: 2,
            taps: 31, // ~15 symbols at T/2
            mu: 0.01,
        }
    }
}

/// Fractionally-Spaced Linear Equalizer
///
/// Simpler than DFE but works at fractional symbol spacing.
/// Good for moderate ISI and timing offset compensation.
pub struct FSE {
    config: FSEConfig,
    constellation: ConstellationType,

    coeffs: Vec<Complex>,
    history: Vec<Complex>,
    
    sample_count: usize,
}

impl FSE {
    pub fn new(config: FSEConfig, constellation: ConstellationType) -> Self {
        let taps = config.taps;
        let mut fse = Self {
            config,
            constellation,
            coeffs: vec![Complex::zero(); taps],
            history: vec![Complex::zero(); taps],
            sample_count: 0,
        };
        
        // Initialize center tap
        fse.coeffs[taps / 2] = Complex::new(1.0, 0.0);
        fse
    }

    /// Process one sample (call at T/2 rate)
    /// Returns Some(symbol) when a decision is made (every N samples)
    pub fn process_sample(&mut self, i: f64, q: f64) -> Option<u8> {
        let input = Complex::new(i, q);

        // Shift into history
        self.history.rotate_right(1);
        self.history[0] = input;

        self.sample_count += 1;

        // Make decision at symbol rate
        if self.sample_count >= self.config.samples_per_symbol {
            self.sample_count = 0;

            // Compute filter output
            let eq_out: Complex = self.coeffs
                .iter()
                .zip(&self.history)
                .map(|(c, h)| *c * *h)
                .sum();

            // Make decision
            let decision = self.constellation.iq_to_symbol(eq_out.re, eq_out.im);

            // Compute error and update
            let (ref_i, ref_q) = self.constellation.symbol_to_iq(decision);
            let reference = Complex::new(ref_i, ref_q);
            let error = eq_out - reference;

            let mu = self.config.mu;
            for (c, h) in self.coeffs.iter_mut().zip(&self.history) {
                *c = *c - error * h.conj() * mu;
            }

            Some(decision)
        } else {
            None
        }
    }

    pub fn reset(&mut self) {
        for c in &mut self.coeffs {
            *c = Complex::zero();
        }
        for h in &mut self.history {
            *h = Complex::zero();
        }
        self.coeffs[self.config.taps / 2] = Complex::new(1.0, 0.0);
        self.sample_count = 0;
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_complex_arithmetic() {
        let a = Complex::new(3.0, 4.0);
        let b = Complex::new(1.0, 2.0);

        // Magnitude
        assert!((a.mag() - 5.0).abs() < 1e-10);

        // Conjugate
        let a_conj = a.conj();
        assert_eq!(a_conj.re, 3.0);
        assert_eq!(a_conj.im, -4.0);

        // Addition
        let sum = a + b;
        assert_eq!(sum.re, 4.0);
        assert_eq!(sum.im, 6.0);

        // Subtraction
        let diff = a - b;
        assert_eq!(diff.re, 2.0);
        assert_eq!(diff.im, 2.0);

        // Multiplication: (3+4j)(1+2j) = 3 + 6j + 4j + 8j² = 3 + 10j - 8 = -5 + 10j
        let prod = a * b;
        assert!((prod.re - (-5.0)).abs() < 1e-10);
        assert!((prod.im - 10.0).abs() < 1e-10);
    }

    #[test]
    fn test_dfe_creation() {
        let dfe = DFE::new(DFEConfig::default(), ConstellationType::Psk8);

        // Check center tap is initialized to 1
        let center = dfe.ff_coeffs.len() / 2;
        assert!((dfe.ff_coeffs[center].re - 1.0).abs() < 1e-10);
        assert!(dfe.ff_coeffs[center].im.abs() < 1e-10);

        // Other taps should be zero
        for (i, c) in dfe.ff_coeffs.iter().enumerate() {
            if i != center {
                assert!(c.mag() < 1e-10);
            }
        }
    }

    #[test]
    fn test_dfe_passthrough_clean_signal() {
        let mut dfe = DFE::new(DFEConfig::default(), ConstellationType::Psk8);

        // With center tap = 1 and clean signal, should pass through unchanged
        let test_symbols = [0u8, 1, 2, 3, 4, 5, 6, 7];
        let mut results = Vec::new();

        for &sym in &test_symbols {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            // Add a few samples to fill the filter
            for _ in 0..5 {
                let _ = dfe.equalize(i, q);
            }
            results.push(dfe.equalize(i, q));
        }

        // After settling, should recover symbols correctly
        // (first few may be wrong due to filter filling)
        let correct = results.iter().zip(&test_symbols[3..])
            .filter(|(&r, &&s)| r == s)
            .count();
        
        assert!(correct >= 4, "Expected at least 4 correct symbols, got {}", correct);
    }

    #[test]
    fn test_dfe_training_mode() {
        let mut dfe = DFE::new(DFEConfig::fast_acquisition(), ConstellationType::Psk8);

        // Train on known sequence
        let training_symbols: Vec<u8> = (0..50).map(|i| (i % 8) as u8).collect();

        for &sym in &training_symbols {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            dfe.train(i, q, sym);
        }

        // MSE should be low after training
        assert!(dfe.mse() < 0.1, "MSE after training: {}", dfe.mse());
    }

    #[test]
    fn test_dfe_with_phase_offset() {
        let mut dfe = DFE::new(DFEConfig::default(), ConstellationType::Psk8);

        // Apply 45° phase rotation (symbol offset of 1)
        let phase_offset = std::f64::consts::PI / 4.0;
        let cos_off = phase_offset.cos();
        let sin_off = phase_offset.sin();

        let test_symbols = [0u8, 0, 0, 0, 4, 4, 4, 4, 0, 0, 0, 0];

        // Train with known symbols
        for &sym in &test_symbols {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            // Rotate
            let i_rot = i * cos_off - q * sin_off;
            let q_rot = i * sin_off + q * cos_off;
            dfe.train(i_rot, q_rot, sym);
        }

        // Now test in decision-directed mode with same rotation
        let test2 = [4u8, 0, 4, 0, 4, 0, 4, 0];
        let mut results = Vec::new();

        for &sym in &test2 {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            let i_rot = i * cos_off - q * sin_off;
            let q_rot = i * sin_off + q * cos_off;
            results.push(dfe.equalize(i_rot, q_rot));
        }

        // Should recover BPSK correctly (0 and 4)
        let bpsk_correct = results.iter().zip(&test2)
            .filter(|(&r, &s)| (r < 4) == (s < 4))
            .count();

        assert!(bpsk_correct >= 6, "BPSK correct: {}/8", bpsk_correct);
    }

    #[test]
    fn test_dfe_with_simple_multipath() {
        let config = DFEConfig {
            ff_taps: 11,
            fb_taps: 5,
            mu: 0.05,
            leakage: 0.999,
            update_threshold: 0.01,
        };
        let mut dfe = DFE::new(config, ConstellationType::Psk8);

        // Simulate simple two-tap channel: h = [1.0, 0.5] (1 symbol delay)
        let h0 = Complex::new(1.0, 0.0);
        let h1 = Complex::new(0.3, 0.2); // Delayed tap with phase shift

        // Training sequence
        let training: Vec<u8> = (0..100).map(|i| (i % 8) as u8).collect();
        let mut prev_iq = Complex::zero();

        for &sym in &training {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            let current = Complex::new(i, q);

            // Channel output: h0 * current + h1 * previous
            let rx = h0 * current + h1 * prev_iq;
            
            dfe.train(rx.re, rx.im, sym);
            prev_iq = current;
        }

        println!("MSE after training: {}", dfe.mse());
        
        // Test in decision-directed mode
        let test_data: Vec<u8> = [0, 4, 0, 0, 4, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4]
            .iter().cloned().collect();
        let mut results = Vec::new();

        for &sym in &test_data {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            let current = Complex::new(i, q);

            let rx = h0 * current + h1 * prev_iq;
            
            results.push(dfe.equalize(rx.re, rx.im));
            prev_iq = current;
        }

        // Check BPSK accuracy
        let bpsk_correct = results.iter().zip(&test_data)
            .filter(|(&r, &s)| (r < 4) == (s < 4))
            .count();

        println!("BPSK correct: {}/{}", bpsk_correct, test_data.len());
        assert!(bpsk_correct >= 12, "Expected at least 12/16 BPSK correct");
    }

    #[test]
    fn test_dfe_reset() {
        let mut dfe = DFE::new(DFEConfig::default(), ConstellationType::Psk8);

        // Process some samples
        for i in 0..20 {
            let sym = (i % 8) as u8;
            let (re, im) = ConstellationType::Psk8.symbol_to_iq(sym);
            dfe.equalize(re, im);
        }

        assert!(dfe.symbols_processed() > 0);

        // Reset
        dfe.reset();

        assert_eq!(dfe.symbols_processed(), 0);
        assert!(dfe.mse() < 1e-10);

        // Center tap should be re-initialized
        let center = dfe.ff_coeffs.len() / 2;
        assert!((dfe.ff_coeffs[center].re - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_fse_creation() {
        let fse = FSE::new(FSEConfig::default(), ConstellationType::Psk8);

        let center = fse.coeffs.len() / 2;
        assert!((fse.coeffs[center].re - 1.0).abs() < 1e-10);
    }
}