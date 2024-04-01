//! Small DSP math helpers

use std::f64::consts::PI;

/// Convert dB to linear scale
#[inline]
pub fn db_to_linear(db: f64) -> f64 {
    10.0_f64.powf(db / 20.0)
}

/// Convert linear to dB scale
#[inline]
pub fn linear_to_db(linear: f64) -> f64 {
    20.0 * linear.log10()
}

/// Normalize angle to [0, 2π)
#[inline]
pub fn normalize_angle(angle: f64) -> f64 {
    let mut a = angle % (2.0 * PI);
    if a < 0.0 {
        a += 2.0 * PI;
    }
    a
}

/// Compute magnitude of complex number
#[inline]
pub fn magnitude(i: f64, q: f64) -> f64 {
    (i * i + q * q).sqrt()
}

/// Compute phase of complex number in radians
#[inline]
pub fn phase(i: f64, q: f64) -> f64 {
    q.atan2(i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_db_conversion() {
        assert!((db_to_linear(0.0) - 1.0).abs() < 1e-10);
        assert!((db_to_linear(20.0) - 10.0).abs() < 1e-10);
        assert!((db_to_linear(-20.0) - 0.1).abs() < 1e-10);
    }

    #[test]
    fn test_normalize_angle() {
        assert!((normalize_angle(0.0) - 0.0).abs() < 1e-10);
        assert!((normalize_angle(2.0 * PI) - 0.0).abs() < 1e-10);
        assert!((normalize_angle(-PI) - PI).abs() < 1e-10);
    }

    #[test]
    fn test_magnitude() {
        assert!((magnitude(3.0, 4.0) - 5.0).abs() < 1e-10);
        assert!((magnitude(1.0, 0.0) - 1.0).abs() < 1e-10);
    }
}