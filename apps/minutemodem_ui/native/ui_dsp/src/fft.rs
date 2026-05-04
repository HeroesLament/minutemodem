use rustfft::{num_complex::Complex, FftPlanner};

/// Precomputed window + FFT plan for a given size.
/// We keep this around so repeated calls don't re-plan.
pub struct FftState {
    size: usize,
    window: Vec<f32>,
    planner_scratch: Vec<Complex<f32>>,
    fft: std::sync::Arc<dyn rustfft::Fft<f32>>,
}

impl FftState {
    pub fn new(size: usize, window_type: &str) -> Self {
        let window = make_window(size, window_type);
        let mut planner = FftPlanner::new();
        let fft = planner.plan_fft_forward(size);
        let scratch_len = fft.get_inplace_scratch_len();

        FftState {
            size,
            window,
            planner_scratch: vec![Complex::new(0.0, 0.0); scratch_len],
            fft,
        }
    }
}

/// Compute dB magnitude bins from s16le audio samples.
///
/// Input:  &[u8] of s16le samples (2 bytes per sample)
/// Output: Vec<u8> of f32-le dB magnitudes, `fft_size / 2` bins
///
/// If fewer than `fft_size` samples are provided, the buffer is zero-padded.
/// If more, only the last `fft_size` samples are used.
pub fn compute_db(samples_bytes: &[u8], fft_size: usize, window_type: &str) -> Vec<u8> {
    // Parse s16le samples to f32 normalized to [-1.0, 1.0]
    let sample_count = samples_bytes.len() / 2;
    let mut samples: Vec<f32> = Vec::with_capacity(sample_count);

    for chunk in samples_bytes.chunks_exact(2) {
        let val = i16::from_le_bytes([chunk[0], chunk[1]]);
        samples.push(val as f32 / 32768.0);
    }

    // Take last fft_size samples or zero-pad
    let mut buffer: Vec<Complex<f32>> = vec![Complex::new(0.0, 0.0); fft_size];
    let window = make_window(fft_size, window_type);

    let offset = if samples.len() >= fft_size {
        samples.len() - fft_size
    } else {
        0
    };

    let copy_len = samples.len().min(fft_size);
    let buf_offset = fft_size - copy_len;

    for i in 0..copy_len {
        let windowed = samples[offset + i] * window[buf_offset + i];
        buffer[buf_offset + i] = Complex::new(windowed, 0.0);
    }

    // FFT in-place
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(fft_size);
    let mut scratch = vec![Complex::new(0.0, 0.0); fft.get_inplace_scratch_len()];
    fft.process_with_scratch(&mut buffer, &mut scratch);

    // Convert to dB magnitude (first half only — positive frequencies)
    let half = fft_size / 2;
    let norm = 1.0 / fft_size as f32;
    let mut output = Vec::with_capacity(half * 4);

    for i in 0..half {
        let re = buffer[i].re * norm;
        let im = buffer[i].im * norm;
        let mag_sq = re * re + im * im;
        // dB with floor at -120
        let db = if mag_sq > 1e-20 {
            10.0 * mag_sq.log10()
        } else {
            -120.0
        };
        output.extend_from_slice(&db.to_le_bytes());
    }

    output
}

/// Compute dB magnitude bins from f32-le audio samples.
///
/// Same as compute_db but input is already f32-le normalized samples.
pub fn compute_db_f32(samples_bytes: &[u8], fft_size: usize, window_type: &str) -> Vec<u8> {
    let sample_count = samples_bytes.len() / 4;
    let mut samples: Vec<f32> = Vec::with_capacity(sample_count);

    for chunk in samples_bytes.chunks_exact(4) {
        let val = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        samples.push(val);
    }

    let mut buffer: Vec<Complex<f32>> = vec![Complex::new(0.0, 0.0); fft_size];
    let window = make_window(fft_size, window_type);

    let offset = if samples.len() >= fft_size {
        samples.len() - fft_size
    } else {
        0
    };

    let copy_len = samples.len().min(fft_size);
    let buf_offset = fft_size - copy_len;

    for i in 0..copy_len {
        let windowed = samples[offset + i] * window[buf_offset + i];
        buffer[buf_offset + i] = Complex::new(windowed, 0.0);
    }

    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(fft_size);
    let mut scratch = vec![Complex::new(0.0, 0.0); fft.get_inplace_scratch_len()];
    fft.process_with_scratch(&mut buffer, &mut scratch);

    let half = fft_size / 2;
    let norm = 1.0 / fft_size as f32;
    let mut output = Vec::with_capacity(half * 4);

    for i in 0..half {
        let re = buffer[i].re * norm;
        let im = buffer[i].im * norm;
        let mag_sq = re * re + im * im;
        let db = if mag_sq > 1e-20 {
            10.0 * mag_sq.log10()
        } else {
            -120.0
        };
        output.extend_from_slice(&db.to_le_bytes());
    }

    output
}

// ---------------------------------------------------------------------------
// Window functions
// ---------------------------------------------------------------------------

fn make_window(size: usize, window_type: &str) -> Vec<f32> {
    match window_type {
        "hann" => hann_window(size),
        "hamming" => hamming_window(size),
        "blackman" => blackman_window(size),
        _ => vec![1.0; size], // "none" / rectangular
    }
}

fn hann_window(size: usize) -> Vec<f32> {
    let n = size as f32;
    (0..size)
        .map(|i| {
            let t = std::f32::consts::PI * 2.0 * i as f32 / (n - 1.0);
            0.5 * (1.0 - t.cos())
        })
        .collect()
}

fn hamming_window(size: usize) -> Vec<f32> {
    let n = size as f32;
    (0..size)
        .map(|i| {
            let t = std::f32::consts::PI * 2.0 * i as f32 / (n - 1.0);
            0.54 - 0.46 * t.cos()
        })
        .collect()
}

fn blackman_window(size: usize) -> Vec<f32> {
    let n = size as f32;
    (0..size)
        .map(|i| {
            let t1 = std::f32::consts::PI * 2.0 * i as f32 / (n - 1.0);
            let t2 = std::f32::consts::PI * 4.0 * i as f32 / (n - 1.0);
            0.42 - 0.5 * t1.cos() + 0.08 * t2.cos()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_db_basic() {
        // 512 samples of silence → should get 256 bins all near -120 dB
        let silence: Vec<u8> = vec![0u8; 512 * 2];
        let result = compute_db(&silence, 512, "hann");
        assert_eq!(result.len(), 256 * 4);

        // All bins should be -120 dB (silence)
        for chunk in result.chunks_exact(4) {
            let db = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            assert!(db <= -100.0, "Expected silence bin <= -100 dB, got {}", db);
        }
    }

    #[test]
    fn test_window_lengths() {
        assert_eq!(hann_window(512).len(), 512);
        assert_eq!(hamming_window(256).len(), 256);
        assert_eq!(blackman_window(1024).len(), 1024);
    }

    #[test]
    fn test_hann_endpoints() {
        let w = hann_window(256);
        // Hann window: zero at endpoints
        assert!(w[0].abs() < 1e-6);
        assert!(w[255].abs() < 1e-6);
        // Peak at center
        assert!(w[127] > 0.99);
    }
}
