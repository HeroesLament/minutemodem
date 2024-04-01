//! Additive White Gaussian Noise generator
//!
//! Uses Box-Muller transform for Gaussian samples.

use rand::Rng;
use rand_chacha::ChaCha8Rng;
use rand::SeedableRng;
use std::f64::consts::PI;

/// AWGN generator with configurable power
pub struct NoiseGenerator {
    /// Standard deviation (sqrt of noise power)
    std_dev: f64,
    
    /// Internal RNG
    rng: ChaCha8Rng,
    
    /// Cached second sample from Box-Muller
    cached: Option<f64>,
}

impl NoiseGenerator {
    pub fn new(noise_power: f64, seed_rng: &mut ChaCha8Rng) -> Self {
        let std_dev = noise_power.sqrt();
        
        // Create a new RNG with a derived seed
        let seed: u64 = seed_rng.gen();
        let rng = ChaCha8Rng::seed_from_u64(seed);
        
        Self {
            std_dev,
            rng,
            cached: None,
        }
    }
    
    /// Generate next Gaussian noise sample using Box-Muller transform
    pub fn next_sample(&mut self) -> f64 {
        // Return cached value if available
        if let Some(cached) = self.cached.take() {
            return cached * self.std_dev;
        }
        
        // Box-Muller transform generates two independent Gaussian samples
        let u1: f64 = self.rng.gen();
        let u2: f64 = self.rng.gen();
        
        // Avoid log(0)
        let u1 = u1.max(1e-10);
        
        let r = (-2.0 * u1.ln()).sqrt();
        let theta = 2.0 * PI * u2;
        
        let z0 = r * theta.cos();
        let z1 = r * theta.sin();
        
        // Cache second sample
        self.cached = Some(z1);
        
        z0 * self.std_dev
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;

    #[test]
    fn test_noise_creation() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let noise = NoiseGenerator::new(0.1, &mut rng);

        assert!((noise.std_dev - 0.1_f64.sqrt()).abs() < 1e-10);
    }

    #[test]
    fn test_noise_statistics() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut noise = NoiseGenerator::new(1.0, &mut rng);

        let n = 10000;
        let samples: Vec<f64> = (0..n).map(|_| noise.next_sample()).collect();

        // Check mean is close to 0
        let mean: f64 = samples.iter().sum::<f64>() / n as f64;
        assert!(mean.abs() < 0.1, "Mean {} should be close to 0", mean);

        // Check variance is close to 1
        let variance: f64 = samples.iter()
            .map(|x| (x - mean).powi(2))
            .sum::<f64>() / n as f64;
        assert!((variance - 1.0).abs() < 0.1, "Variance {} should be close to 1", variance);
    }

    #[test]
    fn test_noise_deterministic() {
        let mut rng1 = ChaCha8Rng::seed_from_u64(42);
        let mut rng2 = ChaCha8Rng::seed_from_u64(42);

        let mut noise1 = NoiseGenerator::new(0.5, &mut rng1);
        let mut noise2 = NoiseGenerator::new(0.5, &mut rng2);

        for _ in 0..100 {
            assert_eq!(noise1.next_sample(), noise2.next_sample());
        }
    }

    #[test]
    fn test_noise_is_gaussian() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut noise = NoiseGenerator::new(1.0, &mut rng);

        let num_samples = 100000usize;
        let samples: Vec<f64> = (0..num_samples).map(|_| noise.next_sample()).collect();

        let mean: f64 = samples.iter().sum::<f64>() / num_samples as f64;
        let std: f64 = (samples.iter().map(|x| (x - mean).powi(2)).sum::<f64>()
            / num_samples as f64).sqrt();

        // For Gaussian: ~68% within 1σ, ~95% within 2σ, ~99.7% within 3σ
        let within_1sigma = samples.iter()
            .filter(|&x| (x - mean).abs() < std)
            .count() as f64 / num_samples as f64;
        let within_2sigma = samples.iter()
            .filter(|&x| (x - mean).abs() < 2.0 * std)
            .count() as f64 / num_samples as f64;
        let within_3sigma = samples.iter()
            .filter(|&x| (x - mean).abs() < 3.0 * std)
            .count() as f64 / num_samples as f64;

        assert!((within_1sigma - 0.683).abs() < 0.02,
            "1σ coverage {} should be ~0.683", within_1sigma);
        assert!((within_2sigma - 0.954).abs() < 0.01,
            "2σ coverage {} should be ~0.954", within_2sigma);
        assert!((within_3sigma - 0.997).abs() < 0.01,
            "3σ coverage {} should be ~0.997", within_3sigma);
    }

    #[test]
    fn test_noise_power_scaling() {
        let powers = [0.1, 1.0, 10.0];
        let mut measured_variances = Vec::new();

        for &power in &powers {
            let mut rng = ChaCha8Rng::seed_from_u64(42);
            let mut noise = NoiseGenerator::new(power, &mut rng);

            let num_samples = 50000usize;
            let samples: Vec<f64> = (0..num_samples).map(|_| noise.next_sample()).collect();

            let mean: f64 = samples.iter().sum::<f64>() / num_samples as f64;
            let variance: f64 = samples.iter()
                .map(|x| (x - mean).powi(2))
                .sum::<f64>() / num_samples as f64;

            measured_variances.push(variance);

            // Variance should approximately equal the configured power
            assert!((variance - power).abs() / power < 0.1,
                "For power={}, measured variance={}", power, variance);
        }
    }

    #[test]
    fn test_noise_numerical_stability() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut noise = NoiseGenerator::new(1.0, &mut rng);

        let num_samples = 1_000_000usize;
        let mut nan_count = 0usize;
        let mut inf_count = 0usize;

        for _ in 0..num_samples {
            let sample = noise.next_sample();
            if sample.is_nan() { nan_count += 1; }
            else if sample.is_infinite() { inf_count += 1; }
        }

        assert_eq!(nan_count, 0, "Found {} NaN values", nan_count);
        assert_eq!(inf_count, 0, "Found {} Inf values", inf_count);
    }
}