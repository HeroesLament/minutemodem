use rustfft::{num_complex::Complex, FftPlanner};

/// Convert real-valued s16le samples to analytic (I/Q) signal via Hilbert transform,
/// then decimate.
///
/// Input:  &[u8] of s16le samples (2 bytes per sample)
/// Output: Vec<u8> of interleaved f32-le I/Q pairs
///
/// The decimation factor controls output density:
///   decimate=1 → every sample, decimate=4 → every 4th sample
///
/// This is the standard frequency-domain Hilbert approach:
///   1. FFT the real signal
///   2. Zero negative frequencies, double positive frequencies
///   3. IFFT → analytic signal (I = real part, Q = imag part)
///   4. Decimate output
pub fn real_to_iq(samples_bytes: &[u8], decimate: usize) -> Vec<u8> {
    let decimate = decimate.max(1);

    // Parse s16le → f32 normalized
    let sample_count = samples_bytes.len() / 2;
    if sample_count == 0 {
        return Vec::new();
    }

    // Round up to power of 2 for FFT efficiency
    let fft_size = sample_count.next_power_of_two();

    let mut buffer: Vec<Complex<f32>> = Vec::with_capacity(fft_size);
    for chunk in samples_bytes.chunks_exact(2) {
        let val = i16::from_le_bytes([chunk[0], chunk[1]]);
        buffer.push(Complex::new(val as f32 / 32768.0, 0.0));
    }
    // Zero-pad to FFT size
    buffer.resize(fft_size, Complex::new(0.0, 0.0));

    let mut planner = FftPlanner::new();

    // Forward FFT
    let fft_fwd = planner.plan_fft_forward(fft_size);
    let mut scratch = vec![Complex::new(0.0, 0.0); fft_fwd.get_inplace_scratch_len()];
    fft_fwd.process_with_scratch(&mut buffer, &mut scratch);

    // Apply Hilbert spectral manipulation:
    //   bin 0 (DC): unchanged
    //   bins 1..N/2-1 (positive freq): multiply by 2
    //   bin N/2 (Nyquist): unchanged
    //   bins N/2+1..N-1 (negative freq): set to zero
    let half = fft_size / 2;

    for i in 1..half {
        buffer[i] = buffer[i].scale(2.0);
    }
    // bin 0 and bin half stay as-is
    for i in (half + 1)..fft_size {
        buffer[i] = Complex::new(0.0, 0.0);
    }

    // Inverse FFT
    let fft_inv = planner.plan_fft_inverse(fft_size);
    let mut scratch_inv = vec![Complex::new(0.0, 0.0); fft_inv.get_inplace_scratch_len()];
    fft_inv.process_with_scratch(&mut buffer, &mut scratch_inv);

    // Normalize IFFT output
    let norm = 1.0 / fft_size as f32;

    // Decimate and output interleaved I/Q (only original sample_count, not padding)
    let output_count = (sample_count + decimate - 1) / decimate;
    let mut output = Vec::with_capacity(output_count * 8);

    let mut idx = 0;
    while idx < sample_count {
        let i_val = buffer[idx].re * norm;
        let q_val = buffer[idx].im * norm;
        output.extend_from_slice(&i_val.to_le_bytes());
        output.extend_from_slice(&q_val.to_le_bytes());
        idx += decimate;
    }

    output
}

/// Same as real_to_iq but input is f32-le samples.
pub fn real_to_iq_f32(samples_bytes: &[u8], decimate: usize) -> Vec<u8> {
    let decimate = decimate.max(1);

    let sample_count = samples_bytes.len() / 4;
    if sample_count == 0 {
        return Vec::new();
    }

    let fft_size = sample_count.next_power_of_two();

    let mut buffer: Vec<Complex<f32>> = Vec::with_capacity(fft_size);
    for chunk in samples_bytes.chunks_exact(4) {
        let val = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        buffer.push(Complex::new(val, 0.0));
    }
    buffer.resize(fft_size, Complex::new(0.0, 0.0));

    let mut planner = FftPlanner::new();

    let fft_fwd = planner.plan_fft_forward(fft_size);
    let mut scratch = vec![Complex::new(0.0, 0.0); fft_fwd.get_inplace_scratch_len()];
    fft_fwd.process_with_scratch(&mut buffer, &mut scratch);

    let half = fft_size / 2;
    for i in 1..half {
        buffer[i] = buffer[i].scale(2.0);
    }
    for i in (half + 1)..fft_size {
        buffer[i] = Complex::new(0.0, 0.0);
    }

    let fft_inv = planner.plan_fft_inverse(fft_size);
    let mut scratch_inv = vec![Complex::new(0.0, 0.0); fft_inv.get_inplace_scratch_len()];
    fft_inv.process_with_scratch(&mut buffer, &mut scratch_inv);

    let norm = 1.0 / fft_size as f32;

    let output_count = (sample_count + decimate - 1) / decimate;
    let mut output = Vec::with_capacity(output_count * 8);

    let mut idx = 0;
    while idx < sample_count {
        let i_val = buffer[idx].re * norm;
        let q_val = buffer[idx].im * norm;
        output.extend_from_slice(&i_val.to_le_bytes());
        output.extend_from_slice(&q_val.to_le_bytes());
        idx += decimate;
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_real_to_iq_empty() {
        let result = real_to_iq(&[], 1);
        assert!(result.is_empty());
    }

    #[test]
    fn test_real_to_iq_silence() {
        let silence: Vec<u8> = vec![0u8; 256 * 2];
        let result = real_to_iq(&silence, 1);
        // Should get 256 I/Q pairs (256 * 8 bytes)
        // All near zero
        assert!(!result.is_empty());
        for chunk in result.chunks_exact(4) {
            let val = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            assert!(val.abs() < 1e-6, "Expected near-zero, got {}", val);
        }
    }

    #[test]
    fn test_decimation() {
        let samples: Vec<u8> = vec![0u8; 256 * 2];
        let full = real_to_iq(&samples, 1);
        let dec4 = real_to_iq(&samples, 4);
        // Decimated by 4 should have ~1/4 the output pairs
        let full_pairs = full.len() / 8;
        let dec4_pairs = dec4.len() / 8;
        assert_eq!(full_pairs, 256);
        assert_eq!(dec4_pairs, 64);
    }
}
