//! Watterson HF channel model implementation
//!
//! MIL-STD-188-110D Appendix E specifies a two-path Rayleigh fading model:
//! - Two independent fading taps with configurable delays
//! - Each tap has independent Gaussian-filtered Rayleigh fading
//! - Doppler bandwidth controls fade rate
//! - AWGN added at output
//!
//! This implementation uses carrier mixing to properly apply complex fading
//! to real passband audio signals:
//! 1. Mix down to baseband I/Q using known carrier frequency
//! 2. Low-pass filter with linear-phase FIR (constant group delay)
//! 3. Apply complex fading coefficients
//! 4. Mix back up to passband (compensating for filter delay)

use rustler::NifStruct;
use rand_chacha::ChaCha8Rng;
use rand::SeedableRng;
use std::f64::consts::PI;

use super::fading::FadingTap;
use super::noise::NoiseGenerator;

/// Channel parameters from Elixir
#[derive(NifStruct, Debug, Clone)]
#[module = "MinutemodemSimnet.Physics.Types.ChannelParams"]
pub struct ChannelParams {
    pub sample_rate: u32,
    pub delay_spread_samples: u32,
    pub doppler_bandwidth_hz: f64,
    pub snr_db: f64,
    pub carrier_freq_hz: f64,
}

/// Channel state for telemetry
#[derive(NifStruct, Debug, Clone)]
#[module = "MinutemodemSimnet.Physics.Types.ChannelState"]
pub struct ChannelState {
    pub sample_index: u64,
    pub tap0_phase: f64,
    pub tap1_phase: f64,
}

/// Linear-phase FIR low-pass filter
/// Uses windowed-sinc design for constant group delay
pub struct FirLowPassFilter {
    coeffs: Vec<f64>,
    history: Vec<f64>,
    write_idx: usize,
    delay: usize, // Group delay in samples = (len-1)/2
}

impl FirLowPassFilter {
    /// Create a FIR LPF using windowed-sinc design
    /// cutoff_hz: cutoff frequency
    /// sample_rate: sample rate in Hz
    /// num_taps: filter length (odd number for symmetric filter)
    fn new(cutoff_hz: f64, sample_rate: f64, num_taps: usize) -> Self {
        // Ensure odd number of taps for type 1 linear phase
        let num_taps = if num_taps % 2 == 0 { num_taps + 1 } else { num_taps };
        let center = (num_taps - 1) / 2;
        
        // Normalized cutoff frequency (0 to 0.5)
        let fc = cutoff_hz / sample_rate;
        
        let mut coeffs = vec![0.0; num_taps];
        
        for i in 0..num_taps {
            let n = i as f64 - center as f64;
            
            // Sinc function
            let sinc = if n.abs() < 1e-10 {
                2.0 * fc
            } else {
                (2.0 * PI * fc * n).sin() / (PI * n)
            };
            
            // Hamming window
            let window = 0.54 - 0.46 * (2.0 * PI * i as f64 / (num_taps - 1) as f64).cos();
            
            coeffs[i] = sinc * window;
        }
        
        // Normalize for unity DC gain
        let sum: f64 = coeffs.iter().sum();
        for c in &mut coeffs {
            *c /= sum;
        }
        
        Self {
            coeffs,
            history: vec![0.0; num_taps],
            write_idx: 0,
            delay: center,
        }
    }
    
    /// Process one sample through the filter
    fn process(&mut self, x: f64) -> f64 {
        // Write new sample
        self.history[self.write_idx] = x;
        
        // Compute convolution
        let mut sum = 0.0;
        let len = self.coeffs.len();
        for i in 0..len {
            let hist_idx = (self.write_idx + len - i) % len;
            sum += self.history[hist_idx] * self.coeffs[i];
        }
        
        // Advance write pointer
        self.write_idx = (self.write_idx + 1) % len;
        
        sum
    }
    
    /// Get the group delay in samples
    fn group_delay(&self) -> usize {
        self.delay
    }
    
    /// Reset filter state
    #[allow(dead_code)]
    fn reset(&mut self) {
        for x in &mut self.history {
            *x = 0.0;
        }
        self.write_idx = 0;
    }
}



/// Watterson two-path channel model with carrier mixing
pub struct WattersonChannel {
    params: ChannelParams,
    sample_index: u64,
    
    // Two independent fading taps
    tap0: FadingTap,
    tap1: FadingTap,
    
    // Delay lines for second tap (I and Q separately)
    delay_line_i: Vec<f64>,
    delay_line_q: Vec<f64>,
    delay_write_idx: usize,
    
    // Carrier NCO
    carrier_phase: f64,
    carrier_phase_inc: f64,
    
    // Linear-phase FIR filters for I and Q channels (tap0)
    lpf_i_0: FirLowPassFilter,
    lpf_q_0: FirLowPassFilter,
    
    // Linear-phase FIR filters for I and Q channels (tap1 - delayed path)
    lpf_i_1: FirLowPassFilter,
    lpf_q_1: FirLowPassFilter,
    
    // FIR filter group delay for carrier phase compensation
    fir_group_delay: usize,
    
    // AWGN generator
    noise: NoiseGenerator,
}

impl WattersonChannel {
    pub fn new(params: ChannelParams, seed: u64) -> Self {
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        
        // Create two independent fading taps with different seeds
        let tap0 = FadingTap::new(
            params.sample_rate as f64,
            params.doppler_bandwidth_hz,
            &mut rng,
        );
        
        let tap1 = FadingTap::new(
            params.sample_rate as f64,
            params.doppler_bandwidth_hz,
            &mut rng,
        );
        
        // Initialize delay lines for tap1 (I and Q)
        let delay_samples = params.delay_spread_samples as usize;
        let delay_len = delay_samples.max(1);
        let delay_line_i = vec![0.0; delay_len];
        let delay_line_q = vec![0.0; delay_len];
        
        // Carrier NCO setup
        let carrier_phase_inc = 2.0 * PI * params.carrier_freq_hz / params.sample_rate as f64;
        
        // FIR LPF parameters
        // Cutoff should be slightly wider than signal bandwidth
        // ALE uses ~2400 Hz bandwidth, so 2800 Hz cutoff gives some margin
        let lpf_cutoff = 2800.0;
        let sample_rate = params.sample_rate as f64;
        
        // Use 31 taps for good stopband attenuation while keeping delay reasonable
        // Group delay = (31-1)/2 = 15 samples ≈ 1.56ms at 9600 Hz
        let num_taps = 31;
        
        let lpf_i_0 = FirLowPassFilter::new(lpf_cutoff, sample_rate, num_taps);
        let lpf_q_0 = FirLowPassFilter::new(lpf_cutoff, sample_rate, num_taps);
        let lpf_i_1 = FirLowPassFilter::new(lpf_cutoff, sample_rate, num_taps);
        let lpf_q_1 = FirLowPassFilter::new(lpf_cutoff, sample_rate, num_taps);
        
        // Store FIR group delay for carrier phase compensation
        let fir_group_delay = lpf_i_0.group_delay();
        
        // Calculate noise power from SNR
        // SNR = signal_power / noise_power
        // Reference signal: sinusoid with amplitude 0.5 has power = 0.5² / 2 = 0.125
        let reference_signal_power = 0.125;
        let noise_power = reference_signal_power * 10.0_f64.powf(-params.snr_db / 10.0);
        let noise = NoiseGenerator::new(noise_power, &mut rng);
        
        Self {
            params: params.clone(),
            sample_index: 0,
            tap0,
            tap1,
            delay_line_i,
            delay_line_q,
            delay_write_idx: 0,
            carrier_phase: 0.0,
            carrier_phase_inc,
            lpf_i_0,
            lpf_q_0,
            lpf_i_1,
            lpf_q_1,
            fir_group_delay,
            noise,
        }
    }
    
    /// Process a block of samples through the channel
    /// Uses carrier mixing to properly apply complex fading to real audio
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        let mut output = Vec::with_capacity(input.len());
        let delay_len = self.delay_line_i.len();
        
        for &sample in input {
            let x = sample as f64;
            
            // === Mix down to baseband ===
            let cos_carrier = self.carrier_phase.cos();
            let sin_carrier = self.carrier_phase.sin();
            
            // Multiply by e^{-jωt} = cos(ωt) - j·sin(ωt) to get baseband I/Q
            // The *2 compensates for mixing loss (we want the baseband component, not half of it)
            // NOTE: Q uses NEGATIVE sin for proper frequency preservation (not inversion)
            let i_raw = x * cos_carrier * 2.0;
            let q_raw = -x * sin_carrier * 2.0;  // Negative for correct e^{-jωt}
            
            // Linear-phase FIR filter to remove 2*carrier component, keeping baseband
            // This introduces a constant group delay
            let i_bb_0 = self.lpf_i_0.process(i_raw);
            let q_bb_0 = self.lpf_q_0.process(q_raw);
            
            // Also filter for the delayed path
            let i_bb_1 = self.lpf_i_1.process(i_raw);
            let q_bb_1 = self.lpf_q_1.process(q_raw);
            
            // === Apply fading to tap 0 (direct path) ===
            let (h0_i, h0_q) = self.tap0.next_sample_complex();
            let h0_i = h0_i as f64;
            let h0_q = h0_q as f64;
            
            // Complex multiply: (i + jq) * (h_i + jh_q) = (i*h_i - q*h_q) + j(i*h_q + q*h_i)
            let i_faded_0 = i_bb_0 * h0_i - q_bb_0 * h0_q;
            let q_faded_0 = i_bb_0 * h0_q + q_bb_0 * h0_i;
            
            // === Apply fading to tap 1 (delayed path) ===
            let (h1_i, h1_q) = self.tap1.next_sample_complex();
            let h1_i = h1_i as f64;
            let h1_q = h1_q as f64;
            
            // Read delayed I/Q from delay line
            let delay_read_idx = (self.delay_write_idx + 1) % delay_len;
            let i_delayed = self.delay_line_i[delay_read_idx];
            let q_delayed = self.delay_line_q[delay_read_idx];
            
            // Write current baseband I/Q to delay line
            self.delay_line_i[self.delay_write_idx] = i_bb_1;
            self.delay_line_q[self.delay_write_idx] = q_bb_1;
            self.delay_write_idx = (self.delay_write_idx + 1) % delay_len;
            
            // Complex multiply for delayed path
            let i_faded_1 = i_delayed * h1_i - q_delayed * h1_q;
            let q_faded_1 = i_delayed * h1_q + q_delayed * h1_i;
            
            // === Combine taps ===
            let (i_combined, q_combined) = if self.params.delay_spread_samples == 0 {
                // Single-path channel - only tap0, no scaling needed
                (i_faded_0, q_faded_0)
            } else {
                // Two-path channel - equal power split
                // Each tap contributes 1/sqrt(2) to maintain unit average power
                let scale = std::f64::consts::FRAC_1_SQRT_2;
                ((i_faded_0 + i_faded_1) * scale, (q_faded_0 + q_faded_1) * scale)
            };
            
            // === Mix back up to passband ===
            // Compute DELAYED carrier phase to compensate for FIR filter group delay
            // The baseband I/Q at this instant corresponds to input from (group_delay) samples ago
            let delay_samples = self.fir_group_delay + 1;
            let phase_delay = delay_samples as f64 * self.carrier_phase_inc;
            let delayed_phase = self.carrier_phase - phase_delay;
            let cos_delayed = delayed_phase.cos();
            let sin_delayed = delayed_phase.sin();
            
            // y = I*cos(wt) - Q*sin(wt)
            let y = i_combined * cos_delayed - q_combined * sin_delayed;
            
            // Advance carrier phase
            self.carrier_phase += self.carrier_phase_inc;
            if self.carrier_phase > 2.0 * PI {
                self.carrier_phase -= 2.0 * PI;
            }
            
            // Add AWGN
            let noisy = y + self.noise.next_sample();
            
            output.push(noisy as f32);
            self.sample_index += 1;
        }
        
        output
    }

    /// Advance channel state without processing samples
    /// Used for time synchronization
    pub fn advance(&mut self, num_samples: usize) {
        for _ in 0..num_samples {
            // Advance fading taps
            self.tap0.next_sample_complex();
            self.tap1.next_sample_complex();
            
            // Advance carrier phase
            self.carrier_phase += self.carrier_phase_inc;
            if self.carrier_phase > 2.0 * PI {
                self.carrier_phase -= 2.0 * PI;
            }
            
            // Advance noise generator
            self.noise.next_sample();
            self.sample_index += 1;
        }
    }
    
    /// Get current channel state for telemetry
    pub fn get_state(&self) -> ChannelState {
        ChannelState {
            sample_index: self.sample_index,
            tap0_phase: self.tap0.get_phase(),
            tap1_phase: self.tap1.get_phase(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    // ========================================================================
    // TEST UTILITIES
    // ========================================================================

    fn generate_tone(freq_hz: f64, sample_rate: f64, num_samples: usize, amplitude: f64) -> Vec<f32> {
        (0..num_samples)
            .map(|i| {
                let t = i as f64 / sample_rate;
                (amplitude * (2.0 * PI * freq_hz * t).cos()) as f32
            })
            .collect()
    }

    fn measure_sinusoid_amplitude(signal: &[f32], freq_hz: f64, sample_rate: f64) -> f64 {
        // Coherent detection: correlate with sin and cos at known frequency
        let mut sum_cos = 0.0_f64;
        let mut sum_sin = 0.0_f64;
        
        for (i, &s) in signal.iter().enumerate() {
            let t = i as f64 / sample_rate;
            let phase = 2.0 * PI * freq_hz * t;
            sum_cos += s as f64 * phase.cos();
            sum_sin += s as f64 * phase.sin();
        }
        
        let n = signal.len() as f64;
        2.0 * ((sum_cos / n).powi(2) + (sum_sin / n).powi(2)).sqrt()
    }

    fn measure_rms(signal: &[f32]) -> f64 {
        let sum_sq: f64 = signal.iter().map(|&x| (x as f64).powi(2)).sum();
        (sum_sq / signal.len() as f64).sqrt()
    }

    fn make_awgn_only_params(snr_db: f64) -> ChannelParams {
        ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 0,
            doppler_bandwidth_hz: 0.0,
            snr_db,
            carrier_freq_hz: 1800.0,
        }
    }

    fn make_fading_only_params(doppler_hz: f64) -> ChannelParams {
        ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 0,
            doppler_bandwidth_hz: doppler_hz,
            snr_db: 80.0, // Effectively no noise
            carrier_freq_hz: 1800.0,
        }
    }

    fn make_multipath_only_params(delay_samples: u32) -> ChannelParams {
        ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: delay_samples,
            doppler_bandwidth_hz: 0.0,
            snr_db: 80.0,
            carrier_freq_hz: 1800.0,
        }
    }

    fn make_clean_channel_params() -> ChannelParams {
        ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 0,
            doppler_bandwidth_hz: 0.0,
            snr_db: 80.0,
            carrier_freq_hz: 1800.0,
        }
    }

    // ========================================================================
    // FIR FILTER TESTS
    // ========================================================================

    #[test]
    fn test_fir_dc_gain_unity() {
        let mut lpf = FirLowPassFilter::new(2800.0, 9600.0, 31);
        
        let mut output = 0.0;
        for _ in 0..100 {
            output = lpf.process(1.0);
        }
        
        assert!((output - 1.0).abs() < 1e-10,
            "DC gain should be exactly 1.0, got {}", output);
    }

    #[test]
    fn test_fir_impulse_response_peak_location() {
        let mut lpf = FirLowPassFilter::new(2800.0, 9600.0, 31);
        let expected_group_delay = 15;
        
        let mut impulse_response = Vec::new();
        for i in 0..64 {
            let input = if i == 0 { 1.0 } else { 0.0 };
            impulse_response.push(lpf.process(input));
        }
        
        let peak_idx = impulse_response
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
            .map(|(i, _)| i)
            .unwrap();
        
        assert_eq!(peak_idx, expected_group_delay,
            "Impulse response peak at {} should be at group delay {}", 
            peak_idx, expected_group_delay);
        
        assert_eq!(lpf.group_delay(), expected_group_delay,
            "group_delay() returns {} but should be {}", 
            lpf.group_delay(), expected_group_delay);
    }

    #[test]
    fn test_fir_impulse_response_symmetric() {
        let mut lpf = FirLowPassFilter::new(2800.0, 9600.0, 31);
        
        let mut impulse_response = Vec::new();
        for i in 0..31 {
            let input = if i == 0 { 1.0 } else { 0.0 };
            impulse_response.push(lpf.process(input));
        }
        
        let n = impulse_response.len();
        for k in 0..n/2 {
            let diff = (impulse_response[k] - impulse_response[n - 1 - k]).abs();
            assert!(diff < 1e-10,
                "Impulse response not symmetric: h[{}]={:.6}, h[{}]={:.6}",
                k, impulse_response[k], n - 1 - k, impulse_response[n - 1 - k]);
        }
    }

    #[test]
    fn test_fir_passband_gain() {
        let sample_rate = 9600.0;
        let cutoff = 2800.0;
        let test_freqs = [200.0, 500.0, 1000.0, 1500.0, 2000.0];
        
        for &freq in &test_freqs {
            let mut lpf = FirLowPassFilter::new(cutoff, sample_rate, 31);
            
            let num_samples = 500;
            let mut output = Vec::new();
            for i in 0..num_samples {
                let t = i as f64 / sample_rate;
                let input = (2.0 * PI * freq * t).cos();
                output.push(lpf.process(input));
            }
            
            let settled_output: Vec<f32> = output[50..].iter().map(|&x| x as f32).collect();
            let output_amplitude = measure_sinusoid_amplitude(&settled_output, freq, sample_rate);
            let gain = output_amplitude;
            
            assert!((gain - 1.0).abs() < 0.05,
                "Passband gain at {} Hz = {:.4}, should be ~1.0", freq, gain);
        }
    }

    #[test]
    fn test_fir_stopband_attenuation() {
        let sample_rate = 9600.0;
        let cutoff = 2800.0;
        let test_freqs = [3500.0, 4000.0, 4500.0];
        
        for &freq in &test_freqs {
            let mut lpf = FirLowPassFilter::new(cutoff, sample_rate, 31);
            
            let num_samples = 500;
            let mut output = Vec::new();
            for i in 0..num_samples {
                let t = i as f64 / sample_rate;
                let input = (2.0 * PI * freq * t).cos();
                output.push(lpf.process(input));
            }
            
            let settled_output: Vec<f32> = output[50..].iter().map(|&x| x as f32).collect();
            let output_amplitude = measure_sinusoid_amplitude(&settled_output, freq, sample_rate);
            let attenuation_db = 20.0 * output_amplitude.log10();
            
            assert!(attenuation_db < -20.0,
                "Stopband attenuation at {} Hz = {:.1} dB, should be < -20 dB", 
                freq, attenuation_db);
        }
    }

    // ========================================================================
    // DELAY LINE TESTS
    // ========================================================================

    #[test]
    fn test_delay_line_zero_means_single_path() {
        let params = make_multipath_only_params(0);
        let mut channel = WattersonChannel::new(params, 42);
        
        let mut input: Vec<f32> = vec![0.0; 100];
        for i in 50..60 {
            let t = (i - 50) as f64 / 9600.0;
            input[i] = (0.5 * (2.0 * PI * 1800.0 * t).cos()) as f32;
        }
        input.extend(vec![0.0; 100]);
        
        let output = channel.process(&input);
        
        let output_energy: Vec<f64> = output.iter().map(|&x| (x as f64).powi(2)).collect();
        let total_energy: f64 = output_energy.iter().sum();
        
        let mut cumulative = 0.0;
        let mut energy_start = 0;
        let mut energy_end = 0;
        
        for (i, &e) in output_energy.iter().enumerate() {
            if cumulative < 0.1 * total_energy && cumulative + e >= 0.1 * total_energy {
                energy_start = i;
            }
            if cumulative < 0.9 * total_energy && cumulative + e >= 0.9 * total_energy {
                energy_end = i;
                break;
            }
            cumulative += e;
        }
        
        let energy_span = energy_end - energy_start;
        
        assert!(energy_span < 80,
            "Energy spread over {} samples suggests multiple paths with delay=0", energy_span);
    }

    #[test]
    fn test_delay_line_creates_echo() {
        // With delay_spread_samples = D, we should see two paths separated by D samples
        // Skip very short delays (< 10 samples) where the two paths overlap too much
        // to reliably distinguish separate peaks
        
        for delay_samples in [10u32, 20, 50] {
            let params = make_multipath_only_params(delay_samples);
            let mut channel = WattersonChannel::new(params, 42);
            
            let mut input: Vec<f32> = vec![0.0; 100];
            for i in 50..58 {
                let t = (i - 50) as f64 / 9600.0;
                input[i] = (0.5 * (2.0 * PI * 1800.0 * t).cos()) as f32;
            }
            input.extend(vec![0.0; 200]);
            
            let output = channel.process(&input);
            
            let envelope: Vec<f64> = output.iter().map(|&x| (x as f64).powi(2)).collect();
            
            let window = 8;
            let smoothed: Vec<f64> = (0..envelope.len())
                .map(|i| {
                    let start = i.saturating_sub(window / 2);
                    let end = (i + window / 2).min(envelope.len());
                    envelope[start..end].iter().sum::<f64>() / (end - start) as f64
                })
                .collect();
            
            let threshold = smoothed.iter().cloned().fold(0.0, f64::max) * 0.2;
            let mut peaks = Vec::new();
            for i in 2..smoothed.len()-2 {
                if smoothed[i] > threshold 
                   && smoothed[i] > smoothed[i-1] 
                   && smoothed[i] > smoothed[i+1]
                   && smoothed[i] > smoothed[i-2]
                   && smoothed[i] > smoothed[i+2] {
                    peaks.push(i);
                }
            }
            
            assert!(peaks.len() >= 2,
                "delay={}: Expected at least 2 peaks, found {}", 
                delay_samples, peaks.len());
            
            if peaks.len() >= 2 {
                let measured_delay = peaks[1] as i32 - peaks[0] as i32;
                let error = (measured_delay - delay_samples as i32).abs();
                
                assert!(error <= 5,
                    "delay={}: Measured peak separation = {}, error = {} samples",
                    delay_samples, measured_delay, error);
            }
        }
    }

    // ========================================================================
    // SNR CALIBRATION TESTS
    // ========================================================================

    #[test]
    fn test_snr_calibration() {
        for target_snr in [10.0, 20.0, 30.0] {
            let params = make_awgn_only_params(target_snr);
            let mut channel = WattersonChannel::new(params.clone(), 42);
            
            let num_samples = 50000;
            let input = generate_tone(1800.0, 9600.0, num_samples, 0.5);
            let _output = channel.process(&input);
            
            let input_rms = measure_rms(&input);
            let signal_power = input_rms.powi(2);
            
            let mut noise_channel = WattersonChannel::new(params, 43);
            let zero_input: Vec<f32> = vec![0.0; num_samples];
            let noise_output = noise_channel.process(&zero_input);
            let noise_rms = measure_rms(&noise_output);
            let noise_power = noise_rms.powi(2);
            
            let measured_snr = 10.0 * (signal_power / noise_power).log10();
            let error = (measured_snr - target_snr).abs();
            
            assert!(error < 2.0,
                "Target SNR = {} dB, measured = {:.1} dB, error = {:.1} dB",
                target_snr, measured_snr, error);
        }
    }

    #[test]
    fn test_noise_power_scales_with_snr() {
        let snr_values = [30.0, 20.0, 10.0];
        let mut noise_powers = Vec::new();
        
        for &snr in &snr_values {
            let params = make_awgn_only_params(snr);
            let mut channel = WattersonChannel::new(params, 42);
            
            let zero_input: Vec<f32> = vec![0.0; 20000];
            let output = channel.process(&zero_input);
            
            let noise_power: f64 = output.iter()
                .map(|&x| (x as f64).powi(2))
                .sum::<f64>() / output.len() as f64;
            
            noise_powers.push(noise_power);
        }
        
        let ratio_1 = noise_powers[1] / noise_powers[0];
        let ratio_2 = noise_powers[2] / noise_powers[1];
        
        assert!((ratio_1 - 10.0).abs() < 2.0,
            "30→20 dB: Noise power ratio = {:.1}, expected ~10", ratio_1);
        assert!((ratio_2 - 10.0).abs() < 2.0,
            "20→10 dB: Noise power ratio = {:.1}, expected ~10", ratio_2);
    }

    #[test]
    fn test_noise_is_additive() {
        let params = make_awgn_only_params(20.0);
        let mut channel = WattersonChannel::new(params, 42);
        
        let input = generate_tone(1800.0, 9600.0, 20000, 0.5);
        let output = channel.process(&input);
        
        let input_power: f64 = input.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / input.len() as f64;
        let output_power: f64 = output.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / output.len() as f64;
        
        assert!(output_power > input_power,
            "Output power {} should exceed input power {}", output_power, input_power);
    }

    // ========================================================================
    // CARRIER PHASE / GROUP DELAY TESTS
    // ========================================================================

    #[test]
    fn test_passthrough_clean_channel() {
        let params = make_clean_channel_params();
        let mut channel = WattersonChannel::new(params, 42);
        
        let input = generate_tone(1800.0, 9600.0, 1000, 0.5);
        let output = channel.process(&input);
        
        let skip = 50;
        let mut max_error = 0.0_f64;
        for i in skip..input.len() {
            let error = (output[i] - input[i]).abs() as f64;
            if error > max_error {
                max_error = error;
            }
        }
        
        assert!(max_error < 0.05,
            "Clean channel max error = {:.4}, should be < 0.05", max_error);
    }

    #[test]
    fn test_output_time_aligned_with_input() {
        let params = make_clean_channel_params();
        let mut channel = WattersonChannel::new(params, 42);
        
        let carrier_hz = 1800.0;
        let sample_rate = 9600.0;
        
        let mut input: Vec<f32> = vec![0.0; 200];
        for i in 0..100 {
            let t = i as f64 / sample_rate;
            input.push((0.5 * (2.0 * PI * carrier_hz * t).cos()) as f32);
        }
        input.extend(vec![0.0; 200]);
        
        let output = channel.process(&input);
        
        let find_energy_centroid = |signal: &[f32]| -> f64 {
            let energy: Vec<f64> = signal.iter().map(|&x| (x as f64).powi(2)).collect();
            let total: f64 = energy.iter().sum();
            if total < 1e-10 {
                return 0.0;
            }
            let weighted_sum: f64 = energy.iter().enumerate()
                .map(|(i, &e)| i as f64 * e)
                .sum();
            weighted_sum / total
        };
        
        let input_centroid = find_energy_centroid(&input);
        let output_centroid = find_energy_centroid(&output);
        
        let lag = output_centroid - input_centroid;
        
        assert!(lag.abs() < 20.0,
            "Output centroid delayed by {:.1} samples, should be ~15 (FIR group delay)", lag);
    }

    #[test]
    fn test_carrier_frequency_response() {
        let params = make_clean_channel_params();
        let carrier_hz = params.carrier_freq_hz;
        
        let mut channel1 = WattersonChannel::new(params.clone(), 42);
        let input_at_carrier = generate_tone(carrier_hz, 9600.0, 1000, 0.5);
        let output_at_carrier = channel1.process(&input_at_carrier);
        let gain_at_carrier = measure_rms(&output_at_carrier[100..]) / measure_rms(&input_at_carrier[100..]);
        
        let mut channel2 = WattersonChannel::new(params.clone(), 42);
        let input_offset = generate_tone(carrier_hz + 500.0, 9600.0, 1000, 0.5);
        let output_offset = channel2.process(&input_offset);
        let gain_offset = measure_rms(&output_offset[100..]) / measure_rms(&input_offset[100..]);
        
        assert!(gain_at_carrier > 0.8,
            "Gain at carrier = {:.3}, should be > 0.8", gain_at_carrier);
        assert!(gain_offset > 0.5,
            "Gain at carrier+500Hz = {:.3}, should be > 0.5", gain_offset);
    }

    // ========================================================================
    // END-TO-END CHANNEL TESTS
    // ========================================================================

    #[test]
    fn test_fading_varies_amplitude() {
        let params = make_fading_only_params(2.0);
        let mut channel = WattersonChannel::new(params, 42);
        
        let input = generate_tone(1800.0, 9600.0, 9600, 0.5);
        let output = channel.process(&input);
        
        let window = 100;
        let mut envelopes = Vec::new();
        for chunk in output[100..].chunks(window) {
            let power: f64 = chunk.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / chunk.len() as f64;
            envelopes.push(power.sqrt());
        }
        
        let mean_env: f64 = envelopes.iter().sum::<f64>() / envelopes.len() as f64;
        let std_env: f64 = (envelopes.iter().map(|&e| (e - mean_env).powi(2)).sum::<f64>() 
            / envelopes.len() as f64).sqrt();
        let cv = std_env / mean_env;
        
        assert!(cv > 0.1,
            "Fading envelope CV = {:.3}, should be > 0.1 (indicating amplitude variation)", cv);
    }

    #[test]
    fn test_numerical_stability_long_run() {
        let params = ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 5,
            doppler_bandwidth_hz: 1.0,
            snr_db: 20.0,
            carrier_freq_hz: 1800.0,
        };
        
        let mut channel = WattersonChannel::new(params, 42);
        
        for chunk_idx in 0..100 {
            let input = generate_tone(1800.0, 9600.0, 10000, 0.5);
            let output = channel.process(&input);
            
            for (i, &y) in output.iter().enumerate() {
                assert!(y.is_finite(),
                    "Non-finite output at chunk {} sample {}: {}", chunk_idx, i, y);
            }
            
            let rms = measure_rms(&output);
            assert!(rms > 0.001 && rms < 100.0,
                "RMS {} out of reasonable bounds at chunk {}", rms, chunk_idx);
        }
    }

    #[test]
    fn test_deterministic_same_seed() {
        let params = ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 5,
            doppler_bandwidth_hz: 1.0,
            snr_db: 20.0,
            carrier_freq_hz: 1800.0,
        };
        
        let input = generate_tone(1800.0, 9600.0, 1000, 0.5);
        
        let mut ch1 = WattersonChannel::new(params.clone(), 42);
        let mut ch2 = WattersonChannel::new(params, 42);
        
        let out1 = ch1.process(&input);
        let out2 = ch2.process(&input);
        
        for (i, (&a, &b)) in out1.iter().zip(out2.iter()).enumerate() {
            assert!((a - b).abs() < 1e-10,
                "Outputs differ at sample {}: {} vs {}", i, a, b);
        }
    }

    #[test]
    fn test_different_seeds_differ() {
        let params = ChannelParams {
            sample_rate: 9600,
            delay_spread_samples: 5,
            doppler_bandwidth_hz: 1.0,
            snr_db: 20.0,
            carrier_freq_hz: 1800.0,
        };
        
        let input = generate_tone(1800.0, 9600.0, 1000, 0.5);
        
        let mut ch1 = WattersonChannel::new(params.clone(), 42);
        let mut ch2 = WattersonChannel::new(params, 12345);
        
        let out1 = ch1.process(&input);
        let out2 = ch2.process(&input);
        
        let mut diff_count = 0;
        for (&a, &b) in out1.iter().zip(out2.iter()) {
            if (a - b).abs() > 0.01 {
                diff_count += 1;
            }
        }
        
        assert!(diff_count > 900,
            "Only {} samples differ between different seeds, should be most", diff_count);
    }

    // ========================================================================
    // MODEM SIGNAL TESTS
    // ========================================================================

    fn generate_bpsk(
        symbols: &[i8],
        carrier_hz: f64,
        symbol_rate: f64,
        sample_rate: f64,
        amplitude: f64,
    ) -> Vec<f32> {
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        let total_samples = symbols.len() * samples_per_symbol;

        (0..total_samples)
            .map(|i| {
                let symbol_idx = i / samples_per_symbol;
                let t = i as f64 / sample_rate;
                let phase = if symbols[symbol_idx] > 0 { 0.0 } else { PI };
                (amplitude * (2.0 * PI * carrier_hz * t + phase).cos()) as f32
            })
            .collect()
    }

    fn decode_bpsk(
        signal: &[f32],
        carrier_hz: f64,
        symbol_rate: f64,
        sample_rate: f64,
        num_symbols: usize,
    ) -> Vec<i8> {
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        
        (0..num_symbols)
            .map(|sym_idx| {
                let start = sym_idx * samples_per_symbol;
                let end = start + samples_per_symbol;
                if end > signal.len() {
                    return 0;
                }
                
                let mut corr = 0.0_f64;
                for i in start..end {
                    let t = i as f64 / sample_rate;
                    let ref_sample = (2.0 * PI * carrier_hz * t).cos();
                    corr += signal[i] as f64 * ref_sample;
                }
                
                if corr > 0.0 { 1 } else { -1 }
            })
            .collect()
    }

    fn generate_fsk(
        bits: &[i8],
        freq_mark: f64,
        freq_space: f64,
        symbol_rate: f64,
        sample_rate: f64,
        amplitude: f64,
    ) -> Vec<f32> {
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        let mut output = Vec::with_capacity(bits.len() * samples_per_symbol);
        let mut phase = 0.0_f64;
        
        for &bit in bits {
            let freq = if bit > 0 { freq_mark } else { freq_space };
            let phase_inc = 2.0 * PI * freq / sample_rate;
            
            for _ in 0..samples_per_symbol {
                output.push((amplitude * phase.cos()) as f32);
                phase += phase_inc;
            }
        }
        
        while phase > 2.0 * PI { phase -= 2.0 * PI; }
        
        output
    }

    /// FSK decoder using non-coherent energy detection
    /// 
    /// Correlates against mark and space frequencies and decides based on
    /// which has higher energy. This is optimal for non-coherent FSK in AWGN.
    /// 
    /// Note: Over Rayleigh fading, this decoder needs adequate SNR (fade margin)
    /// since deep fades cause unavoidable errors. Real systems use FEC and
    /// interleaving to combat burst errors from fades.
    fn decode_fsk(
        signal: &[f32],
        freq_mark: f64,
        freq_space: f64,
        symbol_rate: f64,
        sample_rate: f64,
        num_symbols: usize,
    ) -> Vec<i8> {
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        
        // Decode each symbol using energy detection
        let raw_decisions: Vec<i8> = (0..num_symbols)
            .map(|sym_idx| {
                let start = sym_idx * samples_per_symbol;
                let end = (start + samples_per_symbol).min(signal.len());
                if start >= signal.len() { return 1; }
                
                let mut mark_i = 0.0_f64;
                let mut mark_q = 0.0_f64;
                let mut space_i = 0.0_f64;
                let mut space_q = 0.0_f64;
                
                for i in start..end {
                    let t = i as f64 / sample_rate;
                    let s = signal[i] as f64;
                    
                    mark_i += s * (2.0 * PI * freq_mark * t).cos();
                    mark_q += s * (2.0 * PI * freq_mark * t).sin();
                    space_i += s * (2.0 * PI * freq_space * t).cos();
                    space_q += s * (2.0 * PI * freq_space * t).sin();
                }
                
                let mark_energy = mark_i * mark_i + mark_q * mark_q;
                let space_energy = space_i * space_i + space_q * space_q;
                
                if mark_energy > space_energy { 1 } else { -1 }
            })
            .collect();
        
        raw_decisions
    }

    #[test]
    fn test_bpsk_awgn_channel() {
        let params = make_awgn_only_params(20.0);
        let mut channel = WattersonChannel::new(params, 42);
        
        let num_symbols = 500;
        let symbols: Vec<i8> = (0..num_symbols)
            .map(|i| if (i * 7 + 3) % 13 > 6 { 1 } else { -1 })
            .collect();
        
        let carrier_hz = 1800.0;
        let symbol_rate = 300.0;
        let sample_rate = 9600.0;
        
        let tx = generate_bpsk(&symbols, carrier_hz, symbol_rate, sample_rate, 0.5);
        let rx = channel.process(&tx);
        
        let skip = 5;
        let decoded = decode_bpsk(&rx, carrier_hz, symbol_rate, sample_rate, num_symbols);
        
        let errors: usize = decoded[skip..].iter()
            .zip(symbols[skip..].iter())
            .filter(|(&d, &s)| d != s)
            .count();
        
        let ser = errors as f64 / (num_symbols - skip) as f64;
        
        assert!(ser < 0.02,
            "BPSK SER = {:.3} at 20 dB SNR, should be < 0.02", ser);
    }

    #[test]
    fn test_fsk_fading_channel() {
        // FSK with Rayleigh fading - non-coherent detection survives phase rotation
        // 
        // True Rayleigh fading causes burst errors during deep fades. Without FEC,
        // uncoded FSK has an error floor. We test with multiple seeds and more bits
        // to get a statistically meaningful average BER.
        //
        // Note: This tests the channel model, not optimal modem performance.
        // Real systems use FEC + interleaving to achieve much lower BER.
        
        let freq_mark = 2000.0;
        let freq_space = 1600.0;
        let symbol_rate = 300.0;
        let sample_rate = 9600.0;
        
        let mut total_errors = 0usize;
        let mut total_bits = 0usize;
        
        // Test with multiple seeds to average over fading realizations
        for seed in [42u64, 123, 456, 789, 1011] {
            let params = ChannelParams {
                sample_rate: 9600,
                delay_spread_samples: 0,
                doppler_bandwidth_hz: 0.5,
                snr_db: 30.0,
                carrier_freq_hz: 1800.0,
            };
            
            let mut channel = WattersonChannel::new(params, seed);
            
            let num_bits = 1000;
            let bits: Vec<i8> = (0..num_bits)
                .map(|i| if ((i as u64 * 7 + seed) % 13) > 6 { 1 } else { -1 })
                .collect();
            
            let tx = generate_fsk(&bits, freq_mark, freq_space, symbol_rate, sample_rate, 0.5);
            let rx = channel.process(&tx);
            
            let skip = 5;
            let decoded = decode_fsk(&rx, freq_mark, freq_space, symbol_rate, sample_rate, num_bits);
            
            let errors: usize = decoded[skip..].iter()
                .zip(bits[skip..].iter())
                .filter(|(&d, &s)| d != s)
                .count();
            
            total_errors += errors;
            total_bits += num_bits - skip;
        }
        
        let avg_ber = total_errors as f64 / total_bits as f64;
        
        // With averaging over multiple seeds, expect BER < 15% for uncoded FSK
        // over true Rayleigh fading at moderate SNR
        assert!(avg_ber < 0.15,
            "FSK average BER = {:.3} over {} bits, should be < 0.15", avg_ber, total_bits);
    }

    #[test]
    fn test_timing_preserved() {
        let params = make_clean_channel_params();
        let mut channel = WattersonChannel::new(params, 42);
        
        let carrier_hz = 1800.0;
        let symbol_rate = 300.0;
        let sample_rate = 9600.0;
        let samples_per_symbol = (sample_rate / symbol_rate) as usize;
        
        let preamble: Vec<i8> = vec![1, 1, 1, -1, -1, 1, -1];
        
        let pad_symbols = 20;
        let mut symbols = vec![-1i8; pad_symbols];
        symbols.extend(&preamble);
        symbols.extend(vec![1i8; 30]);
        symbols.extend(vec![-1i8; pad_symbols]);
        
        let tx = generate_bpsk(&symbols, carrier_hz, symbol_rate, sample_rate, 0.5);
        let rx = channel.process(&tx);
        
        let preamble_ref = generate_bpsk(&preamble, carrier_hz, symbol_rate, sample_rate, 0.5);
        
        let mut best_corr = 0.0_f64;
        let mut best_pos = 0usize;
        
        for pos in 0..(rx.len() - preamble_ref.len()) {
            let corr: f64 = rx[pos..pos + preamble_ref.len()].iter()
                .zip(preamble_ref.iter())
                .map(|(&r, &p)| (r * p) as f64)
                .sum();
            
            if corr > best_corr {
                best_corr = corr;
                best_pos = pos;
            }
        }
        
        let expected_pos = pad_symbols * samples_per_symbol;
        let timing_error = (best_pos as i32 - expected_pos as i32).abs();
        
        assert!(timing_error < 20,
            "Preamble detected at {}, expected at {}, error = {} samples",
            best_pos, expected_pos, timing_error);
    }
}