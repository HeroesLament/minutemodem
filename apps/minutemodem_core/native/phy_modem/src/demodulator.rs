//! 8-PSK Demodulator for MIL-STD-188-141D 4G ALE
//!
//! Uses two-pass demodulation for optimal burst timing:
//! 1. Filter entire signal, accumulate energy at each timing phase
//! 2. Find optimal phase from total accumulated energy  
//! 3. Decimate at optimal phase to extract symbols

use std::f64::consts::PI;
use std::sync::Mutex;

use crate::common::*;

pub struct Demodulator {
    pub inner: Mutex<DemodulatorState>,
}

pub struct DemodulatorState {
    sample_rate: u32,
    samples_per_symbol: usize,
    carrier_freq: f64,
    
    // RRC matched filter
    rrc_coeffs: Vec<f64>,
    i_history: Vec<f64>,
    q_history: Vec<f64>,
    
    // Output buffer
    symbol_buffer: Vec<u8>,
}

impl DemodulatorState {
    pub fn new(sample_rate: u32) -> Self {
        let samples_per_symbol = (sample_rate / SYMBOL_RATE) as usize;
        
        let rrc_coeffs = generate_rrc_filter(samples_per_symbol, RRC_ALPHA, RRC_SPAN);
        let filter_len = rrc_coeffs.len();
        
        Self {
            sample_rate,
            samples_per_symbol,
            carrier_freq: CARRIER_FREQ,
            rrc_coeffs,
            i_history: vec![0.0; filter_len],
            q_history: vec![0.0; filter_len],
            symbol_buffer: Vec::new(),
        }
    }
    
    pub fn demodulate(&mut self, samples: &[i16]) -> Vec<u8> {
        self.symbol_buffer.clear();
        
        if samples.is_empty() {
            return self.symbol_buffer.clone();
        }
        
        // PASS 1: Mix, filter, store all I/Q values
        let mut filtered_iq: Vec<(f64, f64)> = Vec::with_capacity(samples.len());
        
        for (sample_idx, &sample) in samples.iter().enumerate() {
            let sample_f = sample as f64 / 32768.0;
            
            // Mix down to baseband
            let t = sample_idx as f64 / self.sample_rate as f64;
            let phase = 2.0 * PI * self.carrier_freq * t;
            
            let lo_i = phase.cos();
            let lo_q = -phase.sin();
            
            let mixed_i = sample_f * lo_i * 2.0;
            let mixed_q = sample_f * lo_q * 2.0;
            
            // Push through matched filter
            self.i_history.remove(0);
            self.i_history.push(mixed_i);
            self.q_history.remove(0);
            self.q_history.push(mixed_q);
            
            // Apply matched filter
            let mut filtered_i = 0.0;
            let mut filtered_q = 0.0;
            for (idx, &coeff) in self.rrc_coeffs.iter().enumerate() {
                filtered_i += self.i_history[idx] * coeff;
                filtered_q += self.q_history[idx] * coeff;
            }
            
            filtered_iq.push((filtered_i, filtered_q));
        }
        
        // PASS 2: Find optimal timing phase
        // Skip first 2*RRC_SPAN symbols (filter settling) for timing estimation
        let skip_samples = 2 * RRC_SPAN * self.samples_per_symbol;
        
        let mut phase_energy = vec![0.0; self.samples_per_symbol];
        
        for (i, &(fi, fq)) in filtered_iq.iter().enumerate().skip(skip_samples) {
            let phase_idx = i % self.samples_per_symbol;
            phase_energy[phase_idx] += fi * fi + fq * fq;
        }
        
        // Find phase with maximum energy
        let mut best_phase = 0;
        let mut max_energy = 0.0;
        for (i, &e) in phase_energy.iter().enumerate() {
            if e > max_energy {
                max_energy = e;
                best_phase = i;
            }
        }
        
        // PASS 3: Decimate at optimal timing phase
        for (i, &(fi, fq)) in filtered_iq.iter().enumerate() {
            if i % self.samples_per_symbol == best_phase {
                let symbol = self.decide_symbol(fi, fq);
                self.symbol_buffer.push(symbol);
            }
        }
        
        self.symbol_buffer.clone()
    }
    
    fn decide_symbol(&self, i: f64, q: f64) -> u8 {
        let angle = q.atan2(i);
        let angle_pos = if angle < 0.0 { angle + 2.0 * PI } else { angle };
        let symbol = ((angle_pos + PI / 8.0) / (PI / 4.0)).floor() as u8;
        symbol & 0x07
    }
    
    pub fn reset(&mut self) {
        for x in self.i_history.iter_mut() { *x = 0.0; }
        for x in self.q_history.iter_mut() { *x = 0.0; }
        self.symbol_buffer.clear();
    }
}