//! First-Principles Tests for Unified Modulator/Demodulator
//!
//! These tests validate each component in isolation before testing the full chain.
//! Following the same methodology used to debug the Clarke fading model.

use std::f64::consts::PI;

// Import from parent module (adjust path as needed for your crate structure)
use super::*;

// =============================================================================
// PART 1: Constellation Mapping Tests
// =============================================================================

#[cfg(test)]
mod constellation_tests {
    use super::*;

    /// Test that PSK8 constellation points are at the correct phases
    #[test]
    fn test_psk8_constellation_phases() {
        for sym in 0..8u8 {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            
            // Expected phase: sym * 45°
            let expected_phase = sym as f64 * PI / 4.0;
            let expected_i = expected_phase.cos();
            let expected_q = expected_phase.sin();
            
            let i_err = (i - expected_i).abs();
            let q_err = (q - expected_q).abs();
            
            assert!(i_err < 1e-10, "PSK8 sym {} I: expected {}, got {}", sym, expected_i, i);
            assert!(q_err < 1e-10, "PSK8 sym {} Q: expected {}, got {}", sym, expected_q, q);
            
            // Verify unit amplitude
            let mag = (i * i + q * q).sqrt();
            assert!((mag - 1.0).abs() < 1e-10, "PSK8 sym {} magnitude: {}", sym, mag);
        }
    }
    
    /// Test that iq_to_symbol correctly inverts symbol_to_iq
    #[test]
    fn test_psk8_roundtrip() {
        for sym in 0..8u8 {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            let recovered = ConstellationType::Psk8.iq_to_symbol(i, q);
            assert_eq!(sym, recovered, "PSK8 roundtrip failed for sym {}: got {}", sym, recovered);
        }
    }
    
    /// Test decision boundaries for PSK8
    /// Each symbol occupies ±22.5° around its nominal phase
    #[test]
    fn test_psk8_decision_boundaries() {
        for sym in 0..8u8 {
            let nominal_phase = sym as f64 * PI / 4.0;
            
            // Test at nominal phase
            let i = nominal_phase.cos();
            let q = nominal_phase.sin();
            assert_eq!(ConstellationType::Psk8.iq_to_symbol(i, q), sym, 
                "Nominal phase {} failed", sym);
            
            // Test just inside boundary (+20°)
            let offset = 20.0 * PI / 180.0;
            let i_plus = (nominal_phase + offset).cos();
            let q_plus = (nominal_phase + offset).sin();
            assert_eq!(ConstellationType::Psk8.iq_to_symbol(i_plus, q_plus), sym,
                "Sym {} at +20° failed", sym);
            
            // Test just inside boundary (-20°)
            let i_minus = (nominal_phase - offset).cos();
            let q_minus = (nominal_phase - offset).sin();
            assert_eq!(ConstellationType::Psk8.iq_to_symbol(i_minus, q_minus), sym,
                "Sym {} at -20° failed", sym);
        }
    }
    
    /// Test that BPSK uses symbols 0 and 4 correctly (needed for ALE)
    #[test]
    fn test_bpsk_phase_mapping() {
        // Symbol 0 should be at phase 0 (I=1, Q=0)
        let (i0, q0) = ConstellationType::Bpsk.symbol_to_iq(0);
        assert!((i0 - 1.0).abs() < 1e-10, "BPSK sym 0 I should be 1, got {}", i0);
        assert!(q0.abs() < 1e-10, "BPSK sym 0 Q should be 0, got {}", q0);
        
        // Symbol 1 should be at phase 180° (I=-1, Q=0)
        let (i1, q1) = ConstellationType::Bpsk.symbol_to_iq(1);
        assert!((i1 + 1.0).abs() < 1e-10, "BPSK sym 1 I should be -1, got {}", i1);
        assert!(q1.abs() < 1e-10, "BPSK sym 1 Q should be 0, got {}", q1);
    }
    
    /// Verify PSK8 symbols 0 and 4 match BPSK symbols 0 and 1
    #[test]
    fn test_psk8_bpsk_compatibility() {
        let (psk8_0_i, psk8_0_q) = ConstellationType::Psk8.symbol_to_iq(0);
        let (psk8_4_i, psk8_4_q) = ConstellationType::Psk8.symbol_to_iq(4);
        
        // PSK8 symbol 0 should match BPSK symbol 0
        assert!((psk8_0_i - 1.0).abs() < 1e-10, "PSK8 sym 0 should be at phase 0");
        assert!(psk8_0_q.abs() < 1e-10);
        
        // PSK8 symbol 4 should match BPSK symbol 1 (phase 180°)
        assert!((psk8_4_i + 1.0).abs() < 1e-10, "PSK8 sym 4 should be at phase 180");
        assert!(psk8_4_q.abs() < 1e-10);
    }
}

// =============================================================================
// PART 2: RRC Filter Tests
// =============================================================================

#[cfg(test)]
mod rrc_filter_tests {
    use super::*;
    
    /// Test that RRC filter has correct length
    #[test]
    fn test_rrc_length() {
        let sps = 4;
        let coeffs = generate_rrc_coeffs(sps);
        let expected_len = 2 * RRC_SPAN * sps + 1;  // 2*6*4 + 1 = 49
        assert_eq!(coeffs.len(), expected_len, 
            "RRC length should be {}, got {}", expected_len, coeffs.len());
    }
    
    /// Test that RRC filter is normalized
    #[test]
    fn test_rrc_normalization() {
        let sps = 4;
        let coeffs = generate_rrc_coeffs(sps);
        
        // Energy should be 1.0 (normalized for unit energy)
        let energy: f64 = coeffs.iter().map(|x| x * x).sum();
        assert!((energy - 1.0).abs() < 1e-6, 
            "RRC energy should be 1.0, got {}", energy);
    }
    
    /// Test RRC symmetry (linear phase)
    #[test]
    fn test_rrc_symmetry() {
        let sps = 4;
        let coeffs = generate_rrc_coeffs(sps);
        let n = coeffs.len();
        
        for i in 0..n/2 {
            let diff = (coeffs[i] - coeffs[n - 1 - i]).abs();
            assert!(diff < 1e-10, 
                "RRC not symmetric at {}: {} vs {}", i, coeffs[i], coeffs[n-1-i]);
        }
    }
    
    /// Test that cascaded TX+RX RRC = raised cosine (Nyquist)
    #[test]
    fn test_rrc_cascade_is_nyquist() {
        let sps = 4;
        let rrc = generate_rrc_coeffs(sps);
        
        // Convolve RRC with itself
        let rc_len = 2 * rrc.len() - 1;
        let mut rc = vec![0.0; rc_len];
        
        for (i, &h1) in rrc.iter().enumerate() {
            for (j, &h2) in rrc.iter().enumerate() {
                rc[i + j] += h1 * h2;
            }
        }
        
        // Find the peak (center of RC)
        let center = rc_len / 2;
        
        // RC should be zero at symbol intervals (Nyquist criterion)
        // except at the center
        for k in 1..=RRC_SPAN {
            let idx_plus = center + k * sps;
            let idx_minus = center - k * sps;
            
            if idx_plus < rc_len {
                let val: f64 = rc[idx_plus] / rc[center];  // Normalize to peak
                assert!(val.abs() < 0.05, 
                    "RC not zero at +{} symbols: {}", k, val);
            }
            if idx_minus < rc_len {
                let val: f64 = rc[idx_minus] / rc[center];
                assert!(val.abs() < 0.05, 
                    "RC not zero at -{} symbols: {}", k, val);
            }
        }
    }
}

// =============================================================================
// PART 3: Modulator Tests (Isolated)
// =============================================================================

#[cfg(test)]
mod modulator_tests {
    use super::*;
    
    const SAMPLE_RATE: u32 = 9600;
    const SYMBOL_RATE: u32 = 2400;
    const CARRIER_FREQ: f64 = 1800.0;
    const SPS: usize = 4;
    
    /// Test that modulator produces correct number of samples
    #[test]
    fn test_modulator_sample_count() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        let symbols = vec![0u8; 10];
        let samples = mod_.modulate(&symbols);
        
        assert_eq!(samples.len(), 10 * SPS, 
            "Expected {} samples, got {}", 10 * SPS, samples.len());
    }
    
    /// Test that modulator output has expected carrier frequency
    #[test]
    fn test_modulator_carrier_frequency() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Send constant symbol (0) to get pure carrier
        let symbols = vec![0u8; 100];
        let samples = mod_.modulate(&symbols);
        
        // Count zero crossings (rough frequency estimate)
        let mut crossings = 0;
        for i in 1..samples.len() {
            if (samples[i] > 0) != (samples[i-1] > 0) {
                crossings += 1;
            }
        }
        
        // Expected crossings for 1800 Hz over 100 symbols at 2400 baud
        // Duration = 100/2400 seconds
        // Crossings = 2 * 1800 * (100/2400) = 150
        let expected_crossings = (2.0 * CARRIER_FREQ * 100.0 / SYMBOL_RATE as f64) as usize;
        
        // Allow 10% tolerance due to edge effects
        let diff = (crossings as i32 - expected_crossings as i32).abs();
        assert!(diff < expected_crossings as i32 / 10, 
            "Zero crossings: expected ~{}, got {}", expected_crossings, crossings);
    }
    
    /// Test that different symbols produce different waveforms
    #[test]
    fn test_modulator_symbol_differentiation() {
        let mut mod0 = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut mod4 = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Symbol 0 (phase 0) vs Symbol 4 (phase 180)
        let samples0 = mod0.modulate(&[0]);
        let samples4 = mod4.modulate(&[4]);
        
        // These should be approximately negatives of each other
        // Check the middle samples (after filter settling)
        let mid = SPS / 2;
        
        // Sum of products should be negative (anti-correlated)
        let corr: i64 = samples0.iter().zip(samples4.iter())
            .map(|(&a, &b)| a as i64 * b as i64)
            .sum();
        
        assert!(corr < 0, "Symbols 0 and 4 should be anti-correlated, got {}", corr);
    }
    
    /// Test modulator phase continuity across symbols
    #[test]
    fn test_modulator_phase_continuity() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Alternate between symbols 0 and 1 (45° apart)
        let symbols: Vec<u8> = (0..20).map(|i| (i % 2) as u8).collect();
        let samples = mod_.modulate(&symbols);
        
        // Check for discontinuities (sudden jumps)
        let mut max_jump = 0i32;
        for i in 1..samples.len() {
            let jump = (samples[i] as i32 - samples[i-1] as i32).abs();
            max_jump = max_jump.max(jump);
        }
        
        // With RRC shaping, jumps should be gradual
        // Max jump should be much less than full scale (32767)
        assert!(max_jump < 20000, 
            "Discontinuity detected: max jump = {}", max_jump);
    }
}

// =============================================================================
// PART 4: Demodulator Tests (Isolated)
// =============================================================================

#[cfg(test)]
mod demodulator_tests {
    use super::*;
    
    const SAMPLE_RATE: u32 = 9600;
    const SYMBOL_RATE: u32 = 2400;
    const CARRIER_FREQ: f64 = 1800.0;
    const SPS: usize = 4;
    
    /// Test demodulator with perfect (analytically generated) signal
    #[test]
    fn test_demodulator_with_perfect_signal() {
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Generate a perfect PSK8 signal analytically
        // Symbol 0 at phase 0, no pulse shaping, just raw carrier
        let num_samples = 200;
        let mut samples = Vec::with_capacity(num_samples);
        
        for i in 0..num_samples {
            let t = i as f64 / SAMPLE_RATE as f64;
            let phase = 2.0 * PI * CARRIER_FREQ * t;
            // Symbol 0: I=1, Q=0, so output = cos(phase)
            let sample = (phase.cos() * 16000.0) as i16;
            samples.push(sample);
        }
        
        let iq = demod.demodulate_iq(&samples);
        
        // Skip settling time
        let skip = 20;
        if iq.len() > skip {
            for (idx, &(i, q)) in iq.iter().skip(skip).enumerate() {
                // For symbol 0, I should be positive, Q near zero
                // But phase may be rotated due to PLL not yet locked
                // Check magnitude instead
                let mag = (i * i + q * q).sqrt();
                assert!(mag > 0.1, "Sample {} has low magnitude: {}", idx, mag);
            }
        }
    }
    
    /// Test 8th power phase detector
    #[test]
    fn test_phase_detector_8th_power() {
        let demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Test with known phase offsets
        for phase_deg in [0.0, 10.0, 20.0, -10.0, -20.0] {
            let phase_rad = phase_deg * PI / 180.0;
            let i = phase_rad.cos();
            let q = phase_rad.sin();
            
            let error = demod.compute_phase_error(i, q);
            
            // Error should be close to the input phase
            // (within the ±22.5° unambiguous range)
            let error_deg = error * 180.0 / PI;
            assert!((error_deg - phase_deg).abs() < 5.0,
                "Phase detector error: input {}°, output {}°", phase_deg, error_deg);
        }
    }
    
    /// Test that 8th power removes PSK modulation
    #[test]
    fn test_phase_detector_modulation_removal() {
        let demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // All 8 PSK8 symbols should give same (near-zero) phase error
        for sym in 0..8u8 {
            let (i, q) = ConstellationType::Psk8.symbol_to_iq(sym);
            let error = demod.compute_phase_error(i, q);
            
            let error_deg = error.abs() * 180.0 / PI;
            assert!(error_deg < 1.0,
                "Symbol {} gave phase error {}° (should be ~0)", sym, error_deg);
        }
    }
}

// =============================================================================
// PART 5: End-to-End Loopback Tests
// =============================================================================

#[cfg(test)]
mod loopback_tests {
    use super::*;
    
    const SAMPLE_RATE: u32 = 9600;
    const SYMBOL_RATE: u32 = 2400;
    const CARRIER_FREQ: f64 = 1800.0;
    
    /// Basic loopback with preamble for synchronization
    #[test]
    fn test_loopback_basic() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Long preamble to ensure PLL and timing lock
        let preamble: Vec<u8> = vec![0; 50];
        let data: Vec<u8> = (0..8).cycle().take(32).collect();
        
        let mut symbols = preamble.clone();
        symbols.extend(&data);
        
        let mut samples = mod_.modulate(&symbols);
        samples.extend(mod_.flush());
        
        let recovered = demod.demodulate(&samples);
        
        println!("TX symbols: {} + {} = {}", preamble.len(), data.len(), symbols.len());
        println!("TX samples: {}", samples.len());
        println!("RX symbols: {}", recovered.len());
        
        // Skip preamble + settling
        let skip = 50 + 15;  // preamble + filter settling
        
        if recovered.len() >= skip + data.len() {
            // Find phase offset (8th power PLL has 8-fold ambiguity)
            let offset = (recovered[skip] + 8 - data[0]) % 8;
            println!("Phase offset: {} (45° × {} = {}°)", offset, offset, offset * 45);
            
            // Count errors with phase correction
            let mut errors = 0;
            for i in 0..data.len() {
                let expected = (data[i] + offset) % 8;
                let actual = recovered[skip + i];
                if actual != expected {
                    errors += 1;
                    println!("  Error at {}: expected {} ({}+{}), got {}", 
                        i, expected, data[i], offset, actual);
                }
            }
            
            println!("Errors: {}/{}", errors, data.len());
            assert!(errors <= 2, "Too many errors: {} out of {}", errors, data.len());
        } else {
            panic!("Not enough recovered symbols: {} (need {})", 
                recovered.len(), skip + data.len());
        }
    }
    
    /// Test loopback with BPSK-only (ALE preamble scenario)
    #[test]
    fn test_loopback_bpsk_only() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Generate BPSK sequence (symbols 0 and 4 only)
        let bpsk_sequence: Vec<u8> = vec![
            0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 4, 0, 0, 4,
            4, 4, 0, 4, 0, 0, 0, 4, 0, 4, 0, 4, 4, 0, 4, 0,
        ];
        
        // Long preamble
        let mut symbols = vec![0u8; 50];
        symbols.extend(&bpsk_sequence);
        symbols.extend(&bpsk_sequence);  // Repeat for more data
        
        let mut samples = mod_.modulate(&symbols);
        samples.extend(mod_.flush());
        
        let recovered = demod.demodulate(&samples);
        
        let skip = 50 + 15;
        let data_len = bpsk_sequence.len() * 2;
        
        if recovered.len() >= skip + data_len {
            // For BPSK, we only care about 0 vs 4 (phase 0 vs 180)
            // Map to BPSK: sym < 4 → 0, sym >= 4 → 1
            let tx_bpsk: Vec<u8> = symbols[50..50+data_len].iter()
                .map(|&s| if s < 4 { 0 } else { 1 })
                .collect();
            
            let rx_bpsk: Vec<u8> = recovered[skip..skip+data_len].iter()
                .map(|&s| if s < 4 { 0 } else { 1 })
                .collect();
            
            // Try both polarities
            let errors_normal: usize = tx_bpsk.iter().zip(&rx_bpsk)
                .filter(|(&t, &r)| t != r).count();
            let errors_inverted: usize = tx_bpsk.iter().zip(&rx_bpsk)
                .filter(|(&t, &r)| t != (1 - r)).count();
            
            let errors = errors_normal.min(errors_inverted);
            let polarity = if errors_normal <= errors_inverted { "normal" } else { "inverted" };
            
            println!("BPSK errors: {}/{} ({})", errors, data_len, polarity);
            
            // Should have very few errors for BPSK
            assert!(errors <= 3, "Too many BPSK errors: {} out of {}", errors, data_len);
        }
    }
    
    /// Test that timing recovery works
    #[test]
    fn test_timing_recovery() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        let symbols: Vec<u8> = vec![0; 100];
        let samples = mod_.modulate(&symbols);
        
        let iq = demod.demodulate_iq(&samples);
        
        // After settling, I/Q magnitude should be stable
        let skip = 20;
        if iq.len() > skip + 20 {
            let mags: Vec<f64> = iq[skip..skip+20].iter()
                .map(|(i, q)| (i*i + q*q).sqrt())
                .collect();
            
            let mean_mag: f64 = mags.iter().sum::<f64>() / mags.len() as f64;
            let variance: f64 = mags.iter()
                .map(|m| (m - mean_mag).powi(2))
                .sum::<f64>() / mags.len() as f64;
            let std_dev = variance.sqrt();
            
            println!("Magnitude: mean={:.3}, std={:.3}, CV={:.1}%", 
                mean_mag, std_dev, 100.0 * std_dev / mean_mag);
            
            // Coefficient of variation should be low (stable timing)
            assert!(std_dev / mean_mag < 0.3, 
                "Timing not stable: CV = {:.1}%", 100.0 * std_dev / mean_mag);
        }
    }
    
    /// Detailed diagnostic test - print intermediate values
    #[test]
    fn test_loopback_diagnostic() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Simple test: send [0, 0, 0, 4, 4, 4, 0, 0, 0]
        let preamble = vec![0u8; 50];
        let data = vec![0, 0, 0, 4, 4, 4, 0, 0, 0, 4, 4, 4];
        
        let mut symbols = preamble.clone();
        symbols.extend(&data);
        
        let samples = mod_.modulate(&symbols);
        
        println!("\n=== MODULATOR OUTPUT ===");
        println!("Samples per symbol: {}", SAMPLE_RATE / SYMBOL_RATE);
        println!("Total samples: {}", samples.len());
        println!("First 20 samples: {:?}", &samples[0..20]);
        
        // Check sample statistics
        let max_sample = samples.iter().map(|&s| s.abs()).max().unwrap();
        let rms: f64 = (samples.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() 
            / samples.len() as f64).sqrt();
        println!("Max amplitude: {}", max_sample);
        println!("RMS amplitude: {:.1}", rms);
        
        let iq = demod.demodulate_iq(&samples);
        
        println!("\n=== DEMODULATOR I/Q ===");
        println!("I/Q pairs: {}", iq.len());
        
        let skip = 50;
        println!("I/Q after preamble (data region):");
        for (i, &(iv, qv)) in iq.iter().skip(skip).take(data.len()).enumerate() {
            let mag = (iv*iv + qv*qv).sqrt();
            let phase = qv.atan2(iv) * 180.0 / PI;
            let sym = ConstellationType::Psk8.iq_to_symbol(iv, qv);
            let expected = data[i];
            let marker = if sym == expected || (sym + 4) % 8 == expected { "✓" } else { "✗" };
            println!("  [{}] I={:+.3} Q={:+.3} mag={:.3} phase={:+.1}° → sym {} (expected {}) {}", 
                i, iv, qv, mag, phase, sym, expected, marker);
        }
        
        let recovered = demod.demodulate(&samples);
        println!("\n=== RECOVERED SYMBOLS ===");
        println!("After skip {}: {:?}", skip, &recovered[skip..skip+data.len().min(recovered.len()-skip)]);
        println!("Expected:      {:?}", data);
    }
}

// =============================================================================
// PART 6: ALE-Specific Tests (Capture Probe)
// =============================================================================

#[cfg(test)]
mod ale_tests {
    use super::*;
    
    const SAMPLE_RATE: u32 = 9600;
    const SYMBOL_RATE: u32 = 2400;
    const CARRIER_FREQ: f64 = 1800.0;
    
    /// The ALE capture probe sequence (first 32 symbols)
    const CAPTURE_PROBE: [u8; 32] = [
        0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 4, 0, 0, 4,
        4, 4, 0, 4, 0, 0, 0, 4, 0, 4, 0, 4, 4, 0, 4, 0,
    ];
    
    /// Test that we can recover the capture probe
    #[test]
    fn test_capture_probe_recovery() {
        let mut mod_ = UnifiedModulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        let mut demod = UnifiedDemodulator::new(
            ConstellationType::Psk8, SAMPLE_RATE, SYMBOL_RATE, CARRIER_FREQ
        );
        
        // Build sequence: preamble + probe + probe + probe
        let mut symbols = vec![0u8; 50];  // Preamble for lock
        symbols.extend_from_slice(&CAPTURE_PROBE);
        symbols.extend_from_slice(&CAPTURE_PROBE);
        symbols.extend_from_slice(&CAPTURE_PROBE);
        
        let mut samples = mod_.modulate(&symbols);
        samples.extend(mod_.flush());
        
        let recovered = demod.demodulate(&samples);
        
        // Check second probe (after settling)
        let probe_start = 50 + 32 + 15;  // preamble + first probe + settling
        
        if recovered.len() >= probe_start + 32 {
            let rx_section = &recovered[probe_start..probe_start + 32];
            
            // BPSK correlation
            let corr: i32 = CAPTURE_PROBE.iter().zip(rx_section)
                .map(|(&t, &r)| {
                    let t_sign = if t < 4 { 1 } else { -1 };
                    let r_sign = if r < 4 { 1 } else { -1 };
                    t_sign * r_sign
                })
                .sum();
            
            println!("Capture probe BPSK correlation: {}/32", corr);
            
            // Should be high positive or high negative (phase ambiguity)
            assert!(corr.abs() >= 28, 
                "Capture probe correlation too low: {}", corr);
        }
    }
}

// =============================================================================
// PART 6: DFE Equalizer Tests
// =============================================================================

#[cfg(test)]
mod dfe_tests {
    use super::*;

    /// Test DFE on clean PSK8 I/Q - should pass through with ~0% SER
    #[test]
    fn test_dfe_clean_passthrough() {
        let constellation = ConstellationType::Psk8;
        let config = DFEConfig::hf_skywave();
        let mut dfe = DFE::new(config, constellation);

        // Generate 200 PSK8 symbols and their I/Q
        let symbols: Vec<u8> = (0..200).map(|i| (i * 3 + 7) as u8 % 8).collect();
        
        let mut errors = 0;
        let mut first_errors: Vec<(usize, u8, u8)> = Vec::new();
        for (idx, &sym) in symbols.iter().enumerate() {
            let (i, q) = constellation.symbol_to_iq(sym);
            let out = dfe.equalize(i, q);
            if out != sym {
                errors += 1;
                if first_errors.len() < 20 {
                    first_errors.push((idx, sym, out));
                }
            }
        }

        let ser = errors as f64 / symbols.len() as f64;
        println!("DFE clean passthrough: {}/{} errors, SER={:.2}%", 
            errors, symbols.len(), ser * 100.0);
        println!("Mode after: {:?}, MSE: {:.6}", dfe.mode(), dfe.mse());
        for (idx, expected, got) in &first_errors {
            println!("  Error at {}: expected {} got {}", idx, expected, got);
        }
        
        // On clean signal, DFE should converge quickly
        // Allow some errors during initial convergence (first ~30 symbols for 21 FF taps)
        assert!(errors < 35, "DFE clean passthrough has too many errors: {}", errors);
    }

    /// Test DFE training on clean PSK8 I/Q
    #[test]
    fn test_dfe_training_clean() {
        let constellation = ConstellationType::Psk8;
        let config = DFEConfig::hf_skywave();
        let mut dfe = DFE::new(config, constellation);

        // Generate symbols
        let symbols: Vec<u8> = (0..500).map(|i| (i * 3 + 7) as u8 % 8).collect();
        
        // Train on first 100 symbols
        let mut train_errors = 0;
        for (idx, &sym) in symbols[..100].iter().enumerate() {
            let (i, q) = constellation.symbol_to_iq(sym);
            let out = dfe.train(i, q, sym);
            if out != sym {
                train_errors += 1;
                if train_errors <= 5 {
                    println!("  Train error at {}: expected {} got {}", idx, sym, out);
                }
            }
        }
        println!("DFE training phase: {}/100 errors, mode: {:?}, MSE: {:.6}", 
            train_errors, dfe.mode(), dfe.mse());

        // Now equalize remaining symbols
        let mut eq_errors = 0;
        for (idx, &sym) in symbols[100..].iter().enumerate() {
            let (i, q) = constellation.symbol_to_iq(sym);
            let out = dfe.equalize(i, q);
            if out != sym {
                eq_errors += 1;
                if eq_errors <= 5 {
                    println!("  Eq error at {}: expected {} got {}", idx + 100, sym, out);
                }
            }
        }
        let ser = eq_errors as f64 / 400.0;
        println!("DFE after training: {}/400 errors, SER={:.2}%, mode: {:?}", 
            eq_errors, ser * 100.0, dfe.mode());
        
        assert!(eq_errors < 5, "DFE after training should be near-perfect: {} errors", eq_errors);
    }

    /// Test full demod+DFE chain on clean signal (what H5a actually does)
    #[test]
    fn test_full_demod_dfe_clean() {
        let constellation = ConstellationType::Psk8;
        let sample_rate = 9600u32;
        let symbol_rate = 2400u32;
        let carrier_freq = 1800.0;

        // Modulate 200 symbols
        let symbols: Vec<u8> = (0..200).map(|i| (i * 3 + 7) as u8 % 8).collect();
        let mut modulator = UnifiedModulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
        let samples = modulator.modulate(&symbols);
        let flush = modulator.flush();
        let all_samples: Vec<i16> = samples.into_iter().chain(flush.into_iter()).collect();

        // Demod WITHOUT equalizer
        let mut demod_basic = UnifiedDemodulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
        let rx_basic = demod_basic.demodulate(&all_samples);
        
        // Demod WITH HF equalizer
        let mut demod_hf = UnifiedDemodulator::with_hf_equalizer(constellation, sample_rate, symbol_rate, carrier_freq);
        let rx_hf = demod_hf.demodulate(&all_samples);

        // Count errors (skip first 12 symbols for filter warmup)
        let skip = 12;
        let mut basic_errors = 0;
        let mut hf_errors = 0;
        let check_len = symbols.len().min(rx_basic.len() - skip).min(rx_hf.len() - skip);
        
        for idx in 0..check_len {
            if rx_basic[idx + skip] != symbols[idx] {
                basic_errors += 1;
            }
            if rx_hf[idx + skip] != symbols[idx] {
                hf_errors += 1;
                if hf_errors <= 10 {
                    println!("  HF error at {}: expected {} got {}", idx, symbols[idx], rx_hf[idx + skip]);
                }
            }
        }

        println!("Basic demod: {}/{} errors ({:.2}%)", basic_errors, check_len, basic_errors as f64 / check_len as f64 * 100.0);
        println!("HF demod:    {}/{} errors ({:.2}%)", hf_errors, check_len, hf_errors as f64 / check_len as f64 * 100.0);
        println!("HF eq mode: {:?}, MSE: {:?}", demod_hf.equalizer_mode(), demod_hf.equalizer_mse());
        
        // Basic should be perfect on clean signal
        assert_eq!(basic_errors, 0, "Basic demod should be perfect on clean signal");
        // HF should also be near-perfect
        assert!(hf_errors < 15, "HF demod should be near-perfect on clean signal: {} errors", hf_errors);
    }

    /// Minimal test: trace first few symbols through small DFE
    #[test]
    fn test_dfe_single_symbol_trace() {
        let constellation = ConstellationType::Psk8;
        let config = DFEConfig {
            ff_taps: 5,
            fb_taps: 2,
            mu: 0.02,
            mu_cma: 0.003,
            leakage: 0.9999,
            update_threshold: 0.15,
            cma_to_dd_threshold: 0.25,
            cma_min_symbols: 64,
        };
        let mut dfe = DFE::new(config, constellation);

        println!("DFE config: ff_taps=5, center=2");
        
        // Feed 10 symbols and trace outputs
        for sym in 0..10u8 {
            let s = sym % 8;
            let (i, q) = constellation.symbol_to_iq(s);
            let out = dfe.equalize(i, q);
            println!("step {}: in=sym{} ({:.3},{:.3}) -> out=sym{} mode={:?}", 
                sym, s, i, q, out, dfe.mode());
        }
    }
}