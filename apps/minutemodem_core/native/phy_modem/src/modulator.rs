//! 8-PSK Modulator for MIL-STD-188-141D 4G ALE
//!
//! Takes tribit symbol indices (0-7) and produces audio samples.

use std::f64::consts::PI;
use std::sync::Mutex;

use crate::common::*;

/// Modulator state held as a BEAM resource
pub struct Modulator {
    pub inner: Mutex<ModulatorState>,
}

pub struct ModulatorState {
    sample_rate: u32,
    samples_per_symbol: usize,
    carrier_freq: f64,
    carrier_phase: f64,
    rrc_coeffs: Vec<f64>,
    i_history: Vec<f64>,
    q_history: Vec<f64>,
}

impl ModulatorState {
    pub fn new(sample_rate: u32) -> Self {
        let samples_per_symbol = (sample_rate / SYMBOL_RATE) as usize;
        
        // Generate RRC filter coefficients
        let rrc_coeffs = generate_rrc_filter(samples_per_symbol, RRC_ALPHA, RRC_SPAN);
        let filter_len = rrc_coeffs.len();
        
        Self {
            sample_rate,
            samples_per_symbol,
            carrier_freq: CARRIER_FREQ,
            carrier_phase: 0.0,
            rrc_coeffs,
            i_history: vec![0.0; filter_len],
            q_history: vec![0.0; filter_len],
        }
    }
    
    pub fn modulate(&mut self, symbols: &[u8]) -> Vec<i16> {
        let mut output: Vec<i16> = Vec::with_capacity(symbols.len() * self.samples_per_symbol);
        
        for &symbol in symbols {
            // Get phase for this symbol
            let phase = PSK8_PHASES[(symbol & 0x07) as usize];
            
            // I/Q components for this symbol
            let i_val = phase.cos();
            let q_val = phase.sin();
            
            // Generate samples for this symbol period
            for sample_idx in 0..self.samples_per_symbol {
                // Shift history and insert new sample
                self.i_history.remove(0);
                self.q_history.remove(0);
                
                if sample_idx == self.samples_per_symbol / 2 {
                    self.i_history.push(i_val);
                    self.q_history.push(q_val);
                } else {
                    self.i_history.push(0.0);
                    self.q_history.push(0.0);
                }
                
                // Apply RRC filter (convolution)
                let mut i_filtered = 0.0;
                let mut q_filtered = 0.0;
                for (idx, &coeff) in self.rrc_coeffs.iter().enumerate() {
                    i_filtered += self.i_history[idx] * coeff;
                    q_filtered += self.q_history[idx] * coeff;
                }
                
                // Modulate onto carrier
                let carrier_i = (2.0 * PI * self.carrier_freq * self.carrier_phase).cos();
                let carrier_q = (2.0 * PI * self.carrier_freq * self.carrier_phase).sin();
                
                // Baseband to passband: I*cos - Q*sin
                let sample = i_filtered * carrier_i - q_filtered * carrier_q;
                
                // Scale to 16-bit range (leave some headroom)
                let sample_i16 = (sample * 24000.0) as i16;
                output.push(sample_i16);
                
                // Advance carrier phase
                self.carrier_phase += 1.0 / self.sample_rate as f64;
                if self.carrier_phase >= 1.0 {
                    self.carrier_phase -= 1.0;
                }
            }
        }
        
        output
    }
    
    /// Flush the filter with zeros to get the tail
    pub fn flush(&mut self) -> Vec<i16> {
        // Need 2*RRC_SPAN to flush both TX and RX filters
        let flush_symbols = vec![0u8; 2 * RRC_SPAN];
        self.modulate(&flush_symbols)
    }
    
    /// Reset state
    pub fn reset(&mut self) {
        self.carrier_phase = 0.0;
        for i in self.i_history.iter_mut() {
            *i = 0.0;
        }
        for q in self.q_history.iter_mut() {
            *q = 0.0;
        }
    }
}