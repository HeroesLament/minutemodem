/// Compute RMS level from s16le audio samples.
///
/// Returns a single f32: the RMS in dBFS (0 dBFS = full scale).
/// Silence returns -120.0 dBFS.
pub fn rms_dbfs(samples_bytes: &[u8]) -> f32 {
    let sample_count = samples_bytes.len() / 2;
    if sample_count == 0 {
        return -120.0;
    }

    let mut sum_sq: f64 = 0.0;
    for chunk in samples_bytes.chunks_exact(2) {
        let val = i16::from_le_bytes([chunk[0], chunk[1]]) as f64 / 32768.0;
        sum_sq += val * val;
    }

    let rms = (sum_sq / sample_count as f64).sqrt();
    if rms < 1e-10 {
        -120.0
    } else {
        (20.0 * rms.log10()) as f32
    }
}

/// Compute peak level from s16le audio samples.
///
/// Returns a single f32: the peak in dBFS.
pub fn peak_dbfs(samples_bytes: &[u8]) -> f32 {
    let sample_count = samples_bytes.len() / 2;
    if sample_count == 0 {
        return -120.0;
    }

    let mut peak: f64 = 0.0;
    for chunk in samples_bytes.chunks_exact(2) {
        let val = (i16::from_le_bytes([chunk[0], chunk[1]]) as f64 / 32768.0).abs();
        if val > peak {
            peak = val;
        }
    }

    if peak < 1e-10 {
        -120.0
    } else {
        (20.0 * peak.log10()) as f32
    }
}

/// Compute both RMS and peak in one pass.
///
/// Returns (rms_dbfs, peak_dbfs) as a tuple encoded into 8 bytes of f32-le.
pub fn levels(samples_bytes: &[u8]) -> Vec<u8> {
    let sample_count = samples_bytes.len() / 2;
    if sample_count == 0 {
        let mut out = Vec::with_capacity(8);
        out.extend_from_slice(&(-120.0f32).to_le_bytes());
        out.extend_from_slice(&(-120.0f32).to_le_bytes());
        return out;
    }

    let mut sum_sq: f64 = 0.0;
    let mut peak: f64 = 0.0;

    for chunk in samples_bytes.chunks_exact(2) {
        let val = i16::from_le_bytes([chunk[0], chunk[1]]) as f64 / 32768.0;
        sum_sq += val * val;
        let abs_val = val.abs();
        if abs_val > peak {
            peak = abs_val;
        }
    }

    let rms = (sum_sq / sample_count as f64).sqrt();

    let rms_db = if rms < 1e-10 {
        -120.0f32
    } else {
        (20.0 * rms.log10()) as f32
    };

    let peak_db = if peak < 1e-10 {
        -120.0f32
    } else {
        (20.0 * peak.log10()) as f32
    };

    let mut out = Vec::with_capacity(8);
    out.extend_from_slice(&rms_db.to_le_bytes());
    out.extend_from_slice(&peak_db.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_silence_rms() {
        let silence = vec![0u8; 512 * 2];
        let db = rms_dbfs(&silence);
        assert!(db <= -100.0, "Expected silence < -100 dBFS, got {}", db);
    }

    #[test]
    fn test_full_scale_peak() {
        // Full-scale positive: 0x7FFF = 32767
        let mut samples = Vec::new();
        for _ in 0..100 {
            samples.extend_from_slice(&32767i16.to_le_bytes());
        }
        let db = peak_dbfs(&samples);
        // Should be very close to 0 dBFS (actually -0.00026 dBFS for 32767/32768)
        assert!(db > -0.01, "Expected near 0 dBFS, got {}", db);
    }

    #[test]
    fn test_levels_returns_8_bytes() {
        let samples = vec![0u8; 256 * 2];
        let result = levels(&samples);
        assert_eq!(result.len(), 8);
    }

    #[test]
    fn test_empty_input() {
        assert_eq!(rms_dbfs(&[]), -120.0);
        assert_eq!(peak_dbfs(&[]), -120.0);
        assert_eq!(levels(&[]).len(), 8);
    }
}
