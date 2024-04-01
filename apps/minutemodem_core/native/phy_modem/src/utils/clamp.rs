//! Clamping utilities for audio samples

/// Clamp a floating point value to i16 range with saturation
#[inline]
pub fn clamp_i16(val: f64) -> i16 {
    if val >= 32767.0 {
        32767
    } else if val <= -32768.0 {
        -32768
    } else {
        val as i16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clamp_in_range() {
        assert_eq!(clamp_i16(0.0), 0);
        assert_eq!(clamp_i16(1000.0), 1000);
        assert_eq!(clamp_i16(-1000.0), -1000);
    }

    #[test]
    fn test_clamp_overflow() {
        assert_eq!(clamp_i16(40000.0), 32767);
        assert_eq!(clamp_i16(-40000.0), -32768);
    }
}