//! Rayleigh fading tap implementation
//!
//! Generates complex Gaussian fading coefficients with specified Doppler spectrum.
//! Uses Gaussian-weighted sum-of-sinusoids for true Rayleigh statistics.
//!
//! ## Method: Gaussian-Weighted Sum of Sinusoids (GWSOS)
//!
//! Unlike the classic Clarke/Jakes method which uses unit-amplitude sinusoids,
//! this implementation weights each sinusoid by a complex Gaussian amplitude.
//! This produces true Rayleigh fading:
//!
//!   h(t) = (1/√N) Σ A_n · exp(j(2π f_n t + φ_n))
//!
//! where A_n = a_n + j·b_n with a_n, b_n ~ N(0, 1/2)
//!
//! This gives:
//! - True Gaussian I/Q (sum of Gaussian-weighted sinusoids → Gaussian by CLT)
//! - Rayleigh magnitude, uniform phase
//! - Correct Jakes/Clarke Doppler spectrum
//! - Autocorrelation following J₀(2πfdτ)

use rand::Rng;
use rand_chacha::ChaCha8Rng;
use rand::SeedableRng;
use std::f64::consts::PI;

const NUM_SINUSOIDS: usize = 64;

/// Single Rayleigh fading tap using Gaussian-weighted sum of sinusoids
pub struct FadingTap {
    sample_rate: f64,
    doppler_hz: f64,
    
    // Per-oscillator Gaussian amplitudes (complex: real + imag)
    amp_real: [f64; NUM_SINUSOIDS],
    amp_imag: [f64; NUM_SINUSOIDS],
    
    // Per-oscillator Doppler frequencies and phases
    freq: [f64; NUM_SINUSOIDS],
    phase: [f64; NUM_SINUSOIDS],
    
    time: f64,
    dt: f64,
    scale: f64,
}

impl FadingTap {
    pub fn new(sample_rate: f64, doppler_hz: f64, rng: &mut ChaCha8Rng) -> Self {
        if doppler_hz == 0.0 {
            return Self::new_static(sample_rate, rng);
        }
        
        let mut amp_real = [0.0; NUM_SINUSOIDS];
        let mut amp_imag = [0.0; NUM_SINUSOIDS];
        let mut freq = [0.0; NUM_SINUSOIDS];
        let mut phase = [0.0; NUM_SINUSOIDS];
        
        // Create independent RNG for this tap
        let tap_seed: u64 = rng.gen();
        let mut tap_rng = ChaCha8Rng::seed_from_u64(tap_seed);
        
        for n in 0..NUM_SINUSOIDS {
            // Gaussian amplitudes: a_n, b_n ~ N(0, 1)
            // Using Box-Muller
            let u1: f64 = tap_rng.gen::<f64>().max(1e-10);
            let u2: f64 = tap_rng.gen();
            let r = (-2.0 * u1.ln()).sqrt();
            let theta = 2.0 * PI * u2;
            amp_real[n] = r * theta.cos();
            amp_imag[n] = r * theta.sin();
            
            // Doppler frequency from angle of arrival
            let alpha = tap_rng.gen::<f64>() * 2.0 * PI - PI;
            freq[n] = doppler_hz * alpha.cos();
            
            // Random initial phase
            phase[n] = tap_rng.gen::<f64>() * 2.0 * PI;
        }
        
        // Scale for unit power: E[|h|²] = 1
        // Each term contributes E[|A_n|²] = E[a²] + E[b²] = 1 + 1 = 2
        // Sum of N terms: E[Σ|A_n|²] = 2N
        // After scaling by 1/√N: E[|h|²] = 2N / N = 2
        // So we need scale = 1/√(2N) for unit power
        let scale = (1.0 / (2.0 * NUM_SINUSOIDS as f64)).sqrt();
        
        Self {
            sample_rate,
            doppler_hz,
            amp_real,
            amp_imag,
            freq,
            phase,
            time: 0.0,
            dt: 1.0 / sample_rate,
            scale,
        }
    }
    
    fn new_static(sample_rate: f64, rng: &mut ChaCha8Rng) -> Self {
        let _tap_seed: u64 = rng.gen(); // consume for determinism
        Self {
            sample_rate,
            doppler_hz: 0.0,
            amp_real: [0.0; NUM_SINUSOIDS],
            amp_imag: [0.0; NUM_SINUSOIDS],
            freq: [0.0; NUM_SINUSOIDS],
            phase: [0.0; NUM_SINUSOIDS],
            time: 0.0,
            dt: 1.0 / sample_rate,
            scale: 1.0,
        }
    }
    
    pub fn next_sample(&mut self) -> f32 {
        let (i, q) = self.next_sample_complex();
        (i * i + q * q).sqrt()
    }
    
    pub fn next_sample_complex(&mut self) -> (f32, f32) {
        if self.doppler_hz == 0.0 {
            return (1.0, 0.0);
        }
        
        let t = self.time;
        self.time += self.dt;
        
        // Prevent unbounded growth
        if self.time > 1e6 {
            self.time = 0.0;
        }
        
        let mut x = 0.0;  // Real part (I)
        let mut y = 0.0;  // Imag part (Q)
        
        for n in 0..NUM_SINUSOIDS {
            let psi = 2.0 * PI * self.freq[n] * t + self.phase[n];
            let cos_psi = psi.cos();
            let sin_psi = psi.sin();
            
            // Complex multiplication: (a + jb) · (cos ψ + j sin ψ)
            // Real: a·cos - b·sin
            // Imag: a·sin + b·cos
            x += self.amp_real[n] * cos_psi - self.amp_imag[n] * sin_psi;
            y += self.amp_real[n] * sin_psi + self.amp_imag[n] * cos_psi;
        }
        
        x *= self.scale;
        y *= self.scale;
        
        (x as f32, y as f32)
    }
    
    pub fn get_phase(&self) -> f64 { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use std::f64::consts::PI;

    fn chi_squared_gof(observed: &[usize], expected: &[f64]) -> (f64, usize) {
        let chi_sq: f64 = observed.iter().zip(expected.iter())
            .filter(|(_, &e)| e > 5.0)
            .map(|(&o, &e)| (o as f64 - e).powi(2) / e)
            .sum();
        (chi_sq, observed.len() - 1)
    }

    fn rayleigh_cdf(r: f64, sigma_sq: f64) -> f64 {
        1.0 - (-r * r / (2.0 * sigma_sq)).exp()
    }
    
    fn theoretical_lcr(rho: f64, doppler_hz: f64) -> f64 {
        (2.0 * PI).sqrt() * doppler_hz * rho * (-rho * rho).exp()
    }
    
    fn theoretical_afd(rho: f64, doppler_hz: f64) -> f64 {
        ((rho * rho).exp() - 1.0) / ((2.0 * PI).sqrt() * doppler_hz * rho)
    }

    fn bessel_j0(x: f64) -> f64 {
        let ax = x.abs();
        if ax < 3.0 {
            let mut sum = 1.0;
            let mut term = 1.0;
            let x2 = x * x / 4.0;
            for k in 1..25 {
                term *= -x2 / (k * k) as f64;
                sum += term;
                if term.abs() < 1e-15 { break; }
            }
            sum
        } else {
            let z = 8.0 / ax;
            let z2 = z * z;
            let p0 = 1.0 - 0.1098628627e-2 * z2 + 0.2734510407e-4 * z2 * z2;
            let q0 = -0.1562499995e-1 * z + 0.1430488765e-3 * z * z2;
            let xx = ax - PI / 4.0;
            (2.0 / (PI * ax)).sqrt() * (xx.cos() * p0 - xx.sin() * q0 * z)
        }
    }

    #[test]
    fn diagnose_gwsos_method() {
        println!("\n\n========== GAUSSIAN-WEIGHTED SUM OF SINUSOIDS ==========\n");
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let tap = FadingTap::new(9600.0, 10.0, &mut rng);
        println!("h(t) = (1/√(2N)) Σ A_n · exp(j(2π f_n t + φ_n))");
        println!("where A_n = a_n + j·b_n, with a_n,b_n ~ N(0,1)");
        println!();
        println!("Sample rate: {} Hz", tap.sample_rate);
        println!("Doppler: {} Hz", tap.doppler_hz);
        println!("Num sinusoids: {}", NUM_SINUSOIDS);
        println!("Scale: {:.6}", tap.scale);
        println!();
        println!("First 5 oscillators:");
        for n in 0..5 {
            println!("  {:2}: A=({:+.3},{:+.3}), f={:+.2}Hz, φ={:.2}rad",
                n, tap.amp_real[n], tap.amp_imag[n], tap.freq[n], tap.phase[n]);
        }
    }

    #[test]
    fn diagnose_fading_depth_distribution() {
        println!("\n\n========== FADING DEPTH ANALYSIS ==========\n");
        
        // Generate long fading sequence
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut tap = FadingTap::new(9600.0, 1.0, &mut rng);  // 1 Hz Doppler (slow)
        
        let duration_sec = 100.0;
        let sample_rate = 9600.0;
        let num_samples = (duration_sec * sample_rate) as usize;
        
        let magnitudes: Vec<f64> = (0..num_samples)
            .map(|_| tap.next_sample() as f64)
            .collect();
        
        // Calculate statistics
        let mean_power: f64 = magnitudes.iter().map(|m| m*m).sum::<f64>() / num_samples as f64;
        let rms = mean_power.sqrt();
        
        // Find minimum (deepest fade)
        let min_mag = magnitudes.iter().cloned().fold(f64::INFINITY, f64::min);
        let max_mag = magnitudes.iter().cloned().fold(0.0f64, f64::max);
        let min_db = 20.0 * (min_mag / rms).log10();
        let max_db = 20.0 * (max_mag / rms).log10();
        
        println!("Doppler: 1.0 Hz (slow fading), Duration: {} sec", duration_sec);
        println!("RMS magnitude: {:.4}", rms);
        println!("Min magnitude: {:.6} ({:.1} dB below RMS)", min_mag, -min_db);
        println!("Max magnitude: {:.4} ({:.1} dB above RMS)", max_mag, max_db);
        println!("Dynamic range: {:.1} dB", max_db - min_db);
        
        // Count samples in deep fades (< -10dB, < -20dB)
        let threshold_10db = rms * 0.316;  // -10 dB
        let threshold_20db = rms * 0.1;    // -20 dB
        let threshold_30db = rms * 0.0316; // -30 dB
        
        let count_10db = magnitudes.iter().filter(|&&m| m < threshold_10db).count();
        let count_20db = magnitudes.iter().filter(|&&m| m < threshold_20db).count();
        let count_30db = magnitudes.iter().filter(|&&m| m < threshold_30db).count();
        
        let pct_10db = 100.0 * count_10db as f64 / num_samples as f64;
        let pct_20db = 100.0 * count_20db as f64 / num_samples as f64;
        let pct_30db = 100.0 * count_30db as f64 / num_samples as f64;
        
        // Theoretical probabilities for Rayleigh: P(r < ρ·rms) = 1 - exp(-ρ²/2)
        let theo_10db = 100.0 * (1.0 - (-0.316f64.powi(2) / 2.0).exp());  // ~4.9%
        let theo_20db = 100.0 * (1.0 - (-0.1f64.powi(2) / 2.0).exp());    // ~0.5%
        let theo_30db = 100.0 * (1.0 - (-0.0316f64.powi(2) / 2.0).exp()); // ~0.05%
        
        println!("\nTime in deep fades:");
        println!("  < -10 dB: {:.2}% (theoretical Rayleigh: {:.2}%)", pct_10db, theo_10db);
        println!("  < -20 dB: {:.3}% (theoretical Rayleigh: {:.3}%)", pct_20db, theo_20db);
        println!("  < -30 dB: {:.4}% (theoretical Rayleigh: {:.4}%)", pct_30db, theo_30db);
        
        // Print ASCII fading envelope (subsample)
        println!("\nFading envelope (first 2 seconds, dB relative to RMS):");
        println!("    +10 |");
        for row in 0..5 {
            let threshold_db = 10.0 - row as f64 * 5.0;
            let threshold_lin = rms * 10f64.powf(threshold_db / 20.0);
            print!("{:+5.0} |", threshold_db);
            for t_idx in 0..80 {
                let sample_idx = t_idx * 240;  // 80 chars = 2 sec at 9600 Hz
                if sample_idx < num_samples {
                    let mag = magnitudes[sample_idx];
                    if mag >= threshold_lin {
                        print!("█");
                    } else {
                        print!(" ");
                    }
                }
            }
            println!();
        }
        println!("    -10 |{}", "-".repeat(80));
        println!("        0                                                              2 sec");
    }

    #[test]
    fn diagnose_iq_statistics() {
        println!("\n\n========== I/Q STATISTICS ==========\n");
        // Use independent taps for i.i.d. samples
        let num_samples = 50000usize;
        let mut i_samples = Vec::with_capacity(num_samples);
        let mut q_samples = Vec::with_capacity(num_samples);
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(4_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            i_samples.push(i as f64);
            q_samples.push(q as f64);
        }
        let i_mean: f64 = i_samples.iter().sum::<f64>() / num_samples as f64;
        let q_mean: f64 = q_samples.iter().sum::<f64>() / num_samples as f64;
        let i_var: f64 = i_samples.iter().map(|x| (x - i_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let q_var: f64 = q_samples.iter().map(|x| (x - q_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let iq_cov: f64 = i_samples.iter().zip(q_samples.iter())
            .map(|(i, q)| (i - i_mean) * (q - q_mean)).sum::<f64>() / num_samples as f64;
        let iq_corr = iq_cov / (i_var.sqrt() * q_var.sqrt() + 1e-10);
        println!("Using {} independent taps (i.i.d. samples)", num_samples);
        println!("I: mean={:+.4}, var={:.4} (expect 0.5)", i_mean, i_var);
        println!("Q: mean={:+.4}, var={:.4} (expect 0.5)", q_mean, q_var);
        println!("I-Q correlation: {:.4} (expect 0)", iq_corr);
        println!("Total power: {:.4} (expect 1.0)", i_var + q_var);
        assert!(i_mean.abs() < 0.05, "I mean {} too far from 0", i_mean);
        assert!(q_mean.abs() < 0.05, "Q mean {} too far from 0", q_mean);
        assert!((i_var - 0.5).abs() < 0.05, "I variance {} not ~0.5", i_var);
        assert!((q_var - 0.5).abs() < 0.05, "Q variance {} not ~0.5", q_var);
        assert!(iq_corr.abs() < 0.05, "I-Q correlation {} too high", iq_corr);
    }

    #[test]
    fn test_fading_tap_creation() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let tap = FadingTap::new(9600.0, 1.0, &mut rng);
        assert_eq!(tap.sample_rate, 9600.0);
        assert_eq!(tap.doppler_hz, 1.0);
    }

    #[test]
    fn test_fading_produces_values() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
        let samples: Vec<f32> = (0..1000).map(|_| tap.next_sample()).collect();
        let mean: f32 = samples.iter().sum::<f32>() / samples.len() as f32;
        assert!(mean > 0.5 && mean < 2.0, "Mean {} out of expected range", mean);
    }

    #[test]
    fn test_fading_deterministic() {
        let mut rng1 = ChaCha8Rng::seed_from_u64(42);
        let mut rng2 = ChaCha8Rng::seed_from_u64(42);
        let mut tap1 = FadingTap::new(9600.0, 1.0, &mut rng1);
        let mut tap2 = FadingTap::new(9600.0, 1.0, &mut rng2);
        for _ in 0..100 { assert_eq!(tap1.next_sample(), tap2.next_sample()); }
    }

    #[test]
    fn test_fading_magnitude_rayleigh_distribution() {
        // Use independent taps for i.i.d. samples
        let num_samples = 50000usize;
        let mut magnitudes = Vec::with_capacity(num_samples);
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(3_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            magnitudes.push(((i*i+q*q) as f64).sqrt());
        }
        let mean: f64 = magnitudes.iter().sum::<f64>() / num_samples as f64;
        let variance: f64 = magnitudes.iter().map(|&m| (m - mean).powi(2)).sum::<f64>() / num_samples as f64;
        let cv = variance.sqrt() / mean;
        let expected_cv = ((4.0 - PI) / PI).sqrt();
        assert!((cv - expected_cv).abs() < 0.05, "CV {} vs expected {}", cv, expected_cv);
    }

    #[test]
    fn test_fading_phase_uniform_distribution() {
        // Use independent taps for proper i.i.d. testing
        let num_samples = 50000usize;
        let num_bins = 8usize;
        let mut bins = vec![0usize; num_bins];
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(2_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            let phase = (q as f64).atan2(i as f64);
            let normalized = (phase + PI) / (2.0 * PI);
            let bin = ((normalized * num_bins as f64) as usize).min(num_bins - 1);
            bins[bin] += 1;
        }
        let expected = num_samples / num_bins;
        for (i, &count) in bins.iter().enumerate() {
            let deviation = (count as f64 - expected as f64).abs() / expected as f64;
            assert!(deviation < 0.10, "Phase bin {} has count {} (expected ~{})", i, count, expected);
        }
    }

    #[test]
    fn test_zero_doppler_no_fading() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut tap = FadingTap::new(9600.0, 0.0, &mut rng);
        for _ in 0..1000 {
            let (i, q) = tap.next_sample_complex();
            assert_eq!(i, 1.0, "Zero Doppler should give I=1");
            assert_eq!(q, 0.0, "Zero Doppler should give Q=0");
        }
    }

    #[test]
    fn test_fading_independence_between_taps() {
        let mut tap0 = FadingTap::new(9600.0, 10.0, &mut ChaCha8Rng::seed_from_u64(100));
        let mut tap1 = FadingTap::new(9600.0, 10.0, &mut ChaCha8Rng::seed_from_u64(200));
        let num_samples = 10000usize;
        let samples0: Vec<f64> = (0..num_samples).map(|_| tap0.next_sample() as f64).collect();
        let samples1: Vec<f64> = (0..num_samples).map(|_| tap1.next_sample() as f64).collect();
        let mean0: f64 = samples0.iter().sum::<f64>() / num_samples as f64;
        let mean1: f64 = samples1.iter().sum::<f64>() / num_samples as f64;
        let std0: f64 = (samples0.iter().map(|x| (x-mean0).powi(2)).sum::<f64>() / num_samples as f64).sqrt();
        let std1: f64 = (samples1.iter().map(|x| (x-mean1).powi(2)).sum::<f64>() / num_samples as f64).sqrt();
        let cross_corr: f64 = samples0.iter().zip(samples1.iter())
            .map(|(a, b)| (a-mean0)*(b-mean1)).sum::<f64>() / (num_samples as f64 * std0 * std1);
        assert!(cross_corr.abs() < 0.1, "Taps should be independent, cross-correlation = {}", cross_corr);
    }

    #[test]
    fn test_fading_power_consistency() {
        // Use independent taps for i.i.d. samples
        let num_samples = 50000usize;
        let mut power_samples = Vec::with_capacity(num_samples);
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(6_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            power_samples.push((i*i + q*q) as f64);
        }
        let mean_power: f64 = power_samples.iter().sum::<f64>() / num_samples as f64;
        assert!(mean_power > 0.9 && mean_power < 1.1, "Mean fading power {} should be ~1.0", mean_power);
    }

    #[test]
    fn test_fading_numerical_stability() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut tap = FadingTap::new(9600.0, 1.0, &mut rng);
        for _ in 0..1_000_000 {
            let (i, q) = tap.next_sample_complex();
            let mag = ((i*i+q*q) as f64).sqrt();
            assert!(!mag.is_nan() && !mag.is_infinite());
        }
    }

    #[test]
    fn test_iq_uncorrelated() {
        // Use independent taps for i.i.d. samples
        let num_samples = 50000usize;
        let mut i_samples = Vec::with_capacity(num_samples);
        let mut q_samples = Vec::with_capacity(num_samples);
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(5_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            i_samples.push(i as f64);
            q_samples.push(q as f64);
        }
        let i_mean: f64 = i_samples.iter().sum::<f64>() / num_samples as f64;
        let q_mean: f64 = q_samples.iter().sum::<f64>() / num_samples as f64;
        let i_var: f64 = i_samples.iter().map(|&x| (x-i_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let q_var: f64 = q_samples.iter().map(|&x| (x-q_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let covariance: f64 = i_samples.iter().zip(q_samples.iter())
            .map(|(&i, &q)| (i-i_mean)*(q-q_mean)).sum::<f64>() / num_samples as f64;
        let correlation = covariance / (i_var.sqrt() * q_var.sqrt());
        println!("I-Q correlation: {:.4} (should be ~0)", correlation);
        assert!(correlation.abs() < 0.05, "I and Q should be uncorrelated, got {}", correlation);
    }

    // =========================================================================
    // FADING STATISTICS VALIDATION TESTS
    // =========================================================================

    #[test]
    fn test_fading_magnitude_pdf_rayleigh_chisq() {
        // Use INDEPENDENT taps for i.i.d. samples (consecutive samples are correlated)
        let num_samples = 50_000usize;
        let num_bins = 20usize;
        let max_r = 3.0;
        let bin_width = max_r / num_bins as f64;
        
        let mut magnitudes = Vec::with_capacity(num_samples);
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            // Skip some samples to get past transient
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            magnitudes.push(((i*i + q*q) as f64).sqrt());
        }
        
        let mean_power: f64 = magnitudes.iter().map(|r| r*r).sum::<f64>() / num_samples as f64;
        let sigma_sq = mean_power / 2.0;
        
        println!("\n========== Rayleigh PDF Chi-Squared Test ==========");
        println!("Using {} independent taps (i.i.d. samples)", num_samples);
        println!("Estimated σ² = {:.4} (expect ~0.5)", sigma_sq);
        
        let mut observed = vec![0usize; num_bins];
        for &r in &magnitudes { observed[((r / bin_width) as usize).min(num_bins - 1)] += 1; }
        
        let mut expected = vec![0.0f64; num_bins];
        for i in 0..num_bins {
            let r_low = i as f64 * bin_width;
            let r_high = (i + 1) as f64 * bin_width;
            expected[i] = (rayleigh_cdf(r_high, sigma_sq) - rayleigh_cdf(r_low, sigma_sq)) * num_samples as f64;
        }
        let (chi_sq, df) = chi_squared_gof(&observed, &expected);
        println!("Chi-squared: {:.2}, df: {}", chi_sq, df);
        
        println!("\nBin         Observed   Expected   Diff%");
        for i in 0..num_bins.min(12) {
            let diff_pct = if expected[i] > 0.0 { 100.0 * (observed[i] as f64 - expected[i]) / expected[i] } else { 0.0 };
            println!("[{:.2},{:.2})   {:6}     {:6.0}    {:+5.1}%",
                i as f64 * bin_width, (i+1) as f64 * bin_width, observed[i], expected[i], diff_pct);
        }
        assert!(chi_sq < 50.0, "Chi-squared {} too high", chi_sq);
    }

    #[test]
    fn test_fading_phase_pdf_uniform_chisq() {
        // Use INDEPENDENT taps for i.i.d. samples
        let num_samples = 50_000usize;
        let num_bins = 16usize;
        
        let mut observed = vec![0usize; num_bins];
        for seed in 0..num_samples {
            let mut rng = ChaCha8Rng::seed_from_u64(1_000_000 + seed as u64);
            let mut tap = FadingTap::new(9600.0, 10.0, &mut rng);
            for _ in 0..100 { tap.next_sample(); }
            let (i, q) = tap.next_sample_complex();
            let phase = (q as f64).atan2(i as f64);
            let normalized = (phase + PI) / (2.0 * PI);
            observed[((normalized * num_bins as f64) as usize).min(num_bins - 1)] += 1;
        }
        let expected_per_bin = num_samples as f64 / num_bins as f64;
        let expected: Vec<f64> = vec![expected_per_bin; num_bins];
        let (chi_sq, df) = chi_squared_gof(&observed, &expected);
        
        println!("\n========== Uniform Phase Chi-Squared Test ==========");
        println!("Using {} independent taps (i.i.d. samples)", num_samples);
        println!("Chi-squared: {:.2}, df: {}", chi_sq, df);
        println!("\nBin (degrees)    Observed   Expected   Diff%");
        for i in 0..num_bins {
            let angle_start = -180.0 + i as f64 * 360.0 / num_bins as f64;
            let diff_pct = 100.0 * (observed[i] as f64 - expected_per_bin) / expected_per_bin;
            println!("[{:+6.1}°,{:+6.1}°)  {:6}     {:6.0}    {:+5.1}%",
                angle_start, angle_start + 360.0/num_bins as f64, observed[i], expected_per_bin, diff_pct);
        }
        assert!(chi_sq < 40.0, "Chi-squared {} too high", chi_sq);
    }

    #[test]
    fn test_level_crossing_rate() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let doppler_hz = 10.0;
        let sample_rate = 9600.0;
        let mut tap = FadingTap::new(sample_rate, doppler_hz, &mut rng);
        let duration_sec = 100.0;
        let num_samples = (duration_sec * sample_rate) as usize;
        
        let magnitudes: Vec<f64> = (0..num_samples).map(|_| tap.next_sample() as f64).collect();
        let rms = (magnitudes.iter().map(|&m| m*m).sum::<f64>() / num_samples as f64).sqrt();
        
        println!("\n========== Level Crossing Rate Test ==========");
        println!("Doppler: {} Hz, Duration: {} sec, RMS: {:.4}", doppler_hz, duration_sec, rms);
        println!("\nρ (thresh/rms)  Measured LCR   Theoretical LCR   Error%");
        
        for &rho in &[0.5, 0.707, 1.0, 1.414, 2.0] {
            let threshold = rho * rms;
            let crossings = (1..num_samples).filter(|&i| magnitudes[i-1] < threshold && magnitudes[i] >= threshold).count();
            let measured = crossings as f64 / duration_sec;
            let theoretical = theoretical_lcr(rho, doppler_hz);
            let error_pct = 100.0 * (measured - theoretical).abs() / theoretical;
            println!("ρ = {:.3}         {:8.2}       {:8.2}          {:5.1}%", rho, measured, theoretical, error_pct);
            assert!(error_pct < 30.0, "LCR at ρ={} error {}% too high", rho, error_pct);
        }
    }

    #[test]
    fn test_average_fade_duration() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let doppler_hz = 10.0;
        let sample_rate = 9600.0;
        let mut tap = FadingTap::new(sample_rate, doppler_hz, &mut rng);
        let duration_sec = 200.0;
        let num_samples = (duration_sec * sample_rate) as usize;
        
        let magnitudes: Vec<f64> = (0..num_samples).map(|_| tap.next_sample() as f64).collect();
        let rms = (magnitudes.iter().map(|&m| m*m).sum::<f64>() / num_samples as f64).sqrt();
        
        println!("\n========== Average Fade Duration Test ==========");
        println!("Doppler: {} Hz, Duration: {} sec, RMS: {:.4}", doppler_hz, duration_sec, rms);
        println!("\nρ (thresh/rms)  Measured AFD(ms)  Theoretical AFD(ms)  Error%");
        
        for &rho in &[0.5, 0.707, 1.0] {
            let threshold = rho * rms;
            let mut fade_durations: Vec<f64> = Vec::new();
            let mut in_fade = false;
            let mut fade_start = 0usize;
            for i in 0..num_samples {
                if magnitudes[i] < threshold {
                    if !in_fade { in_fade = true; fade_start = i; }
                } else if in_fade {
                    fade_durations.push((i - fade_start) as f64 / sample_rate);
                    in_fade = false;
                }
            }
            if fade_durations.is_empty() { continue; }
            let measured = fade_durations.iter().sum::<f64>() / fade_durations.len() as f64;
            let theoretical = theoretical_afd(rho, doppler_hz);
            let error_pct = 100.0 * (measured - theoretical).abs() / theoretical;
            println!("ρ = {:.3}         {:8.2}          {:8.2}             {:5.1}%",
                rho, measured * 1000.0, theoretical * 1000.0, error_pct);
            assert!(error_pct < 40.0, "AFD at ρ={} error {}% too high", rho, error_pct);
        }
    }

    #[test]
    fn test_fading_autocorrelation_bessel() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let doppler_hz = 10.0;
        let sample_rate = 9600.0;
        let mut tap = FadingTap::new(sample_rate, doppler_hz, &mut rng);
        let num_samples = 96000usize;
        
        let mut i_samples = Vec::with_capacity(num_samples);
        let mut q_samples = Vec::with_capacity(num_samples);
        for _ in 0..num_samples {
            let (i, q) = tap.next_sample_complex();
            i_samples.push(i as f64);
            q_samples.push(q as f64);
        }
        let i_mean: f64 = i_samples.iter().sum::<f64>() / num_samples as f64;
        let q_mean: f64 = q_samples.iter().sum::<f64>() / num_samples as f64;
        let i_var: f64 = i_samples.iter().map(|&x| (x-i_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let q_var: f64 = q_samples.iter().map(|&x| (x-q_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let total_var = i_var + q_var;
        
        println!("\n========== Autocorrelation vs Bessel J₀ Test ==========");
        println!("Doppler: {} Hz, Sample rate: {} Hz", doppler_hz, sample_rate);
        println!("\nLag (ms)   τ*fd    Measured ρ   J₀(2πfdτ)   Error");
        
        for &lag_samples in &[0usize, 24, 48, 96, 192, 480, 960, 2400, 4800] {
            let tau = lag_samples as f64 / sample_rate;
            let n = num_samples - lag_samples;
            let mut sum = 0.0;
            for i in 0..n {
                sum += (i_samples[i] - i_mean) * (i_samples[i + lag_samples] - i_mean);
                sum += (q_samples[i] - q_mean) * (q_samples[i + lag_samples] - q_mean);
            }
            let measured = sum / (n as f64 * total_var);
            let theoretical = bessel_j0(2.0 * PI * doppler_hz * tau);
            let error = (measured - theoretical).abs();
            println!("{:6.1}     {:.3}      {:+.4}       {:+.4}      {:.4}",
                tau * 1000.0, tau * doppler_hz, measured, theoretical, error);
            let tolerance = if lag_samples < 100 { 0.15 } else { 0.25 };
            assert!(error < tolerance, "Autocorr at lag {}: error {} > {}", lag_samples, error, tolerance);
        }
    }

    #[test]
    fn test_coherence_time() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let doppler_hz = 10.0;
        let sample_rate = 9600.0;
        let mut tap = FadingTap::new(sample_rate, doppler_hz, &mut rng);
        let num_samples = 96000usize;
        
        let mut i_samples = Vec::with_capacity(num_samples);
        let mut q_samples = Vec::with_capacity(num_samples);
        for _ in 0..num_samples {
            let (i, q) = tap.next_sample_complex();
            i_samples.push(i as f64);
            q_samples.push(q as f64);
        }
        let i_mean: f64 = i_samples.iter().sum::<f64>() / num_samples as f64;
        let q_mean: f64 = q_samples.iter().sum::<f64>() / num_samples as f64;
        let i_var: f64 = i_samples.iter().map(|&x| (x-i_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let q_var: f64 = q_samples.iter().map(|&x| (x-q_mean).powi(2)).sum::<f64>() / num_samples as f64;
        let total_var = i_var + q_var;
        
        let mut coherence_samples = 0usize;
        for lag in 1..4800 {
            let n = num_samples - lag;
            let mut sum = 0.0;
            for i in 0..n {
                sum += (i_samples[i] - i_mean) * (i_samples[i + lag] - i_mean);
                sum += (q_samples[i] - q_mean) * (q_samples[i + lag] - q_mean);
            }
            if sum / (n as f64 * total_var) < 0.5 { coherence_samples = lag; break; }
        }
        let measured_tc = coherence_samples as f64 / sample_rate;
        let theoretical_tc = 0.242 / doppler_hz;
        let error_pct = 100.0 * (measured_tc - theoretical_tc).abs() / theoretical_tc;
        
        println!("\n========== Coherence Time Test ==========");
        println!("Measured Tc: {:.2} ms, Theoretical: {:.2} ms, Error: {:.1}%",
            measured_tc * 1000.0, theoretical_tc * 1000.0, error_pct);
        assert!(error_pct < 25.0, "Coherence time error {}% too high", error_pct);
    }

    #[test]
    #[ignore]
    fn test_jakes_spectrum_bandlimited() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let doppler_hz = 10.0;
        let sample_rate = 9600.0;
        let mut tap = FadingTap::new(sample_rate, doppler_hz, &mut rng);
        let num_samples = 96000usize;
        let samples: Vec<f64> = (0..num_samples).map(|_| tap.next_sample() as f64).collect();
        
        let freq_res = sample_rate / num_samples as f64;
        let doppler_bin = (doppler_hz / freq_res) as usize;
        let (mut low, mut high) = (0.0, 0.0);
        for k in 0..(num_samples / 2) {
            let (mut re, mut im) = (0.0, 0.0);
            for (i, &x) in samples.iter().enumerate() {
                let angle = -2.0 * PI * k as f64 * i as f64 / num_samples as f64;
                re += x * angle.cos();
                im += x * angle.sin();
            }
            let power = (re*re + im*im) / (num_samples * num_samples) as f64;
            if k <= doppler_bin { low += power; } else { high += power; }
        }
        assert!(low / (high + 1e-10) > 5.0, "Spectrum not bandlimited");
    }

    #[test]
    fn diagnose_fsk_fading_impact() {
        println!("\n\n========== FSK FADING IMPACT ANALYSIS ==========\n");
        
        // Simulate what happens to a signal during fading
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut tap = FadingTap::new(9600.0, 1.0, &mut rng);  // 1 Hz Doppler
        
        let sample_rate = 9600.0;
        let symbol_rate = 100.0;  // Typical FSK baud rate
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        let num_symbols = 1000usize;
        
        // Simulate symbol-by-symbol SNR degradation
        let mut snr_degradation = Vec::with_capacity(num_symbols);
        
        for _ in 0..num_symbols {
            // Average fading over one symbol period
            let mut symbol_power = 0.0;
            for _ in 0..samples_per_symbol {
                let (i, q) = tap.next_sample_complex();
                symbol_power += (i*i + q*q) as f64;
            }
            symbol_power /= samples_per_symbol as f64;
            
            // SNR degradation in dB (relative to no-fading case)
            let snr_loss_db = -10.0 * symbol_power.log10();
            snr_degradation.push(snr_loss_db);
        }
        
        // Statistics
        let mean_loss: f64 = snr_degradation.iter().sum::<f64>() / num_symbols as f64;
        let max_loss = snr_degradation.iter().cloned().fold(0.0f64, f64::max);
        let min_loss = snr_degradation.iter().cloned().fold(f64::INFINITY, f64::min);
        
        // Count symbols with significant degradation
        let count_3db = snr_degradation.iter().filter(|&&x| x > 3.0).count();
        let count_6db = snr_degradation.iter().filter(|&&x| x > 6.0).count();
        let count_10db = snr_degradation.iter().filter(|&&x| x > 10.0).count();
        let count_20db = snr_degradation.iter().filter(|&&x| x > 20.0).count();
        
        println!("Configuration:");
        println!("  Doppler: 1.0 Hz, Symbol rate: {} baud", symbol_rate);
        println!("  Samples per symbol: {}", samples_per_symbol);
        println!("  Total symbols: {}", num_symbols);
        println!();
        println!("Per-symbol SNR degradation (dB below ideal):");
        println!("  Mean: {:.2} dB", mean_loss);
        println!("  Range: {:.2} to {:.2} dB", min_loss, max_loss);
        println!();
        println!("Symbol error probability increases:");
        println!("  > 3 dB loss:  {:4} symbols ({:.1}%)", count_3db, 100.0 * count_3db as f64 / num_symbols as f64);
        println!("  > 6 dB loss:  {:4} symbols ({:.1}%)", count_6db, 100.0 * count_6db as f64 / num_symbols as f64);
        println!("  > 10 dB loss: {:4} symbols ({:.1}%)", count_10db, 100.0 * count_10db as f64 / num_symbols as f64);
        println!("  > 20 dB loss: {:4} symbols ({:.1}%)", count_20db, 100.0 * count_20db as f64 / num_symbols as f64);
        
        // Histogram of SNR degradation
        println!("\nSNR degradation histogram:");
        let bins = [0.0, 3.0, 6.0, 10.0, 15.0, 20.0, 30.0, f64::INFINITY];
        for i in 0..bins.len()-1 {
            let count = snr_degradation.iter()
                .filter(|&&x| x >= bins[i] && x < bins[i+1])
                .count();
            let pct = 100.0 * count as f64 / num_symbols as f64;
            let bar_len = (pct * 0.5) as usize;
            print!("  {:5.0}-{:5.0} dB: {:4} ({:5.1}%) ", bins[i], bins[i+1].min(99.0), count, pct);
            println!("{}", "█".repeat(bar_len.min(40)));
        }
        
        println!("\nNote: For FSK at 20dB SNR, >10dB fading loss causes errors.");
        println!("If {:.1}% of symbols see >10dB loss, expect ~{:.1}% BER floor.",
            100.0 * count_10db as f64 / num_symbols as f64,
            100.0 * count_10db as f64 / num_symbols as f64 * 0.5);  // Rough estimate
    }
}