//! Walsh-16 correlator with iterative per-block equalization
//!
//! High-performance implementation of the soft Walsh decoder.
//! Replaces the Elixir phase-search + equalization loop with native code.
//!
//! Architecture:
//!   Pass 1: Phase-search correlation on raw I/Q → quadbit decisions
//!   Pass 2..N: Per-block ZF equalization using previous decisions → re-correlate
//!   Score tracking: keeps best result across passes
//!
//! All lookup tables are precomputed at construction time.
//! Working buffers are pre-allocated and reused across frames.

use std::f64::consts::PI;

// ============================================================================
// Walsh-16 patterns
// ============================================================================

/// Base Walsh-16 patterns (16 chips each). Value 0 = +1, value 4 = -1.
const WALSH_16_BASE: [[i8; 16]; 16] = [
    [ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], // 0x0
    [ 1,-1, 1,-1, 1,-1, 1,-1, 1,-1, 1,-1, 1,-1, 1,-1], // 0x1
    [ 1, 1,-1,-1, 1, 1,-1,-1, 1, 1,-1,-1, 1, 1,-1,-1], // 0x2
    [ 1,-1,-1, 1, 1,-1,-1, 1, 1,-1,-1, 1, 1,-1,-1, 1], // 0x3
    [ 1, 1, 1, 1,-1,-1,-1,-1, 1, 1, 1, 1,-1,-1,-1,-1], // 0x4
    [ 1,-1, 1,-1,-1, 1,-1, 1, 1,-1, 1,-1,-1, 1,-1, 1], // 0x5
    [ 1, 1,-1,-1,-1,-1, 1, 1, 1, 1,-1,-1,-1,-1, 1, 1], // 0x6
    [ 1,-1,-1, 1,-1, 1, 1,-1, 1,-1,-1, 1,-1, 1, 1,-1], // 0x7
    [ 1, 1, 1, 1, 1, 1, 1, 1,-1,-1,-1,-1,-1,-1,-1,-1], // 0x8
    [ 1,-1, 1,-1, 1,-1, 1,-1,-1, 1,-1, 1,-1, 1,-1, 1], // 0x9
    [ 1, 1,-1,-1, 1, 1,-1,-1,-1,-1, 1, 1,-1,-1, 1, 1], // 0xA
    [ 1,-1,-1, 1, 1,-1,-1, 1,-1, 1, 1,-1,-1, 1, 1,-1], // 0xB
    [ 1, 1, 1, 1,-1,-1,-1,-1,-1,-1,-1,-1, 1, 1, 1, 1], // 0xC
    [ 1,-1, 1,-1,-1, 1,-1, 1,-1, 1,-1, 1, 1,-1, 1,-1], // 0xD
    [ 1, 1,-1,-1,-1,-1, 1, 1,-1,-1, 1, 1, 1, 1,-1,-1], // 0xE
    [ 1,-1,-1, 1,-1, 1, 1,-1,-1, 1, 1,-1, 1,-1,-1, 1], // 0xF
];

// ============================================================================
// Telemetry
// ============================================================================

#[derive(Clone, Debug)]
pub struct WalshBlockTelemetry {
    pub score: f64,
    pub phase: f64,
    pub channel_mag: f64,
    pub channel_phase: f64,
    pub eq_gain: f64,  // score improvement from equalization
}

#[derive(Clone, Debug)]
pub struct WalshFrameTelemetry {
    pub pass_scores: Vec<f64>,      // total score per pass
    pub pass_used: usize,           // which pass was selected
    pub blocks: Vec<WalshBlockTelemetry>,  // per-block detail (final pass)
    pub avg_score: f64,
    pub min_score: f64,
    pub phase_spread: f64,          // std dev of block phases
}

// ============================================================================
// Correlator
// ============================================================================

pub struct WalshCorrelator {
    // Config
    pub(crate) n_phases: usize,
    pub(crate) n_passes: usize,
    
    // Precomputed lookup tables
    phase_cos: Vec<f64>,
    phase_sin: Vec<f64>,
    pub(crate) walsh_signs: [[f64; 64]; 16],  // Full 64-chip patterns as ±1.0
    
    // Working buffers (reused across calls)
    rot_i: Vec<f64>,
    
    // Telemetry
    telemetry_enabled: bool,
    last_telemetry: Option<WalshFrameTelemetry>,
}

impl WalshCorrelator {
    pub fn new(n_phases: usize, n_passes: usize) -> Self {
        // Precompute trig tables
        let phase_cos: Vec<f64> = (0..n_phases)
            .map(|k| (k as f64 * PI / n_phases as f64).cos())
            .collect();
        let phase_sin: Vec<f64> = (0..n_phases)
            .map(|k| (k as f64 * PI / n_phases as f64).sin())
            .collect();
        
        // Precompute full 64-chip Walsh patterns as ±1.0
        let mut walsh_signs = [[0.0f64; 64]; 16];
        for qb in 0..16 {
            for rep in 0..4 {
                for chip in 0..16 {
                    walsh_signs[qb][rep * 16 + chip] = WALSH_16_BASE[qb][chip] as f64;
                }
            }
        }
        
        WalshCorrelator {
            n_phases,
            n_passes,
            phase_cos,
            phase_sin,
            walsh_signs,
            rot_i: vec![0.0; 64],
            telemetry_enabled: false,
            last_telemetry: None,
        }
    }
    
    pub fn enable_telemetry(&mut self) {
        self.telemetry_enabled = true;
    }
    
    pub fn take_telemetry(&mut self) -> Option<WalshFrameTelemetry> {
        self.last_telemetry.take()
    }
    
    /// Decode a frame of descrambled I/Q pairs.
    ///
    /// Input: descrambled_iq (6144 pairs), scramble_offsets (6144 u8s)
    /// Output: (quadbits [96], scores [96])
    ///
    /// The scramble_offsets are needed for equalization: to reconstruct
    /// the transmitted (scrambled) I/Q from the Walsh decisions.
    pub fn decode_frame(
        &mut self,
        descrambled_iq: &[(f64, f64)],
        raw_iq: &[(f64, f64)],
        scramble_offsets: &[u8],
    ) -> (Vec<u8>, Vec<f64>) {
        let n_blocks = descrambled_iq.len() / 64;
        
        // Pass 1: correlate raw descrambled I/Q
        let (mut best_quadbits, mut best_scores) = self.correlate_all_blocks(descrambled_iq);
        let mut best_total: f64 = best_scores.iter().sum();
        
        let mut pass_scores = vec![best_total];
        let pass1_scores = best_scores.clone();
        
        // Passes 2..N: equalize → re-descramble → correlate
        for _pass in 1..self.n_passes {
            // Equalize raw I/Q using current quadbit decisions
            let equalized = self.equalize_per_block(raw_iq, scramble_offsets, &best_quadbits);
            
            // Re-descramble equalized I/Q
            let desc_eq = self.descramble_with_offsets(&equalized, scramble_offsets);
            
            // Correlate
            let (new_quadbits, new_scores) = self.correlate_all_blocks(&desc_eq);
            let new_total: f64 = new_scores.iter().sum();
            
            pass_scores.push(new_total);
            
            if new_total > best_total {
                best_quadbits = new_quadbits;
                best_scores = new_scores;
                best_total = new_total;
            }
        }
        
        // Build telemetry if enabled
        if self.telemetry_enabled {
            let pass_used = pass_scores.iter()
                .enumerate()
                .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
                .map(|(i, _)| i)
                .unwrap_or(0);
            
            let avg_score = best_total / n_blocks as f64;
            let min_score = best_scores.iter().cloned().fold(f64::INFINITY, f64::min);
            
            // Compute per-block telemetry (re-correlate to get phases)
            let mut blocks = Vec::with_capacity(n_blocks);
            for blk in 0..n_blocks {
                let start = blk * 64;
                let end = start + 64;
                if end <= descrambled_iq.len() {
                    let block_iq = &descrambled_iq[start..end];
                    let (_, _, phase, _) = self.correlate_block(block_iq);
                    
                    let eq_gain = if pass_scores.len() > 1 {
                        best_scores[blk] - pass1_scores[blk]
                    } else {
                        0.0
                    };
                    
                    // Channel estimate from equalization
                    let (ch_mag, ch_phase) = if blk < n_blocks {
                        self.estimate_channel_block(
                            &raw_iq[start..end],
                            scramble_offsets,
                            start,
                            best_quadbits[blk],
                        )
                    } else {
                        (1.0, 0.0)
                    };
                    
                    blocks.push(WalshBlockTelemetry {
                        score: best_scores[blk],
                        phase,
                        channel_mag: ch_mag,
                        channel_phase: ch_phase,
                        eq_gain,
                    });
                }
            }
            
            // Phase spread
            let mean_phase = blocks.iter().map(|b| b.phase).sum::<f64>() / blocks.len() as f64;
            let phase_var = blocks.iter()
                .map(|b| {
                    let d = b.phase - mean_phase;
                    // Wrap to [-π, π]
                    let d = if d > PI { d - 2.0 * PI } else if d < -PI { d + 2.0 * PI } else { d };
                    d * d
                })
                .sum::<f64>() / blocks.len() as f64;
            
            self.last_telemetry = Some(WalshFrameTelemetry {
                pass_scores,
                pass_used,
                blocks,
                avg_score,
                min_score,
                phase_spread: phase_var.sqrt(),
            });
        }
        
        (best_quadbits, best_scores)
    }
    
    /// Decode frame returning soft bit LLRs for soft Viterbi.
    ///
    /// Same multi-pass equalization as decode_frame, but the final pass
    /// computes per-bit LLRs from the Walsh correlation scores.
    ///
    /// Returns: (quadbits [96], scores [96], soft_bits [384])
    /// where soft_bits has 4 LLRs per quadbit (MSB first).
    pub fn decode_frame_soft(
        &mut self,
        descrambled_iq: &[(f64, f64)],
        raw_iq: &[(f64, f64)],
        scramble_offsets: &[u8],
    ) -> (Vec<u8>, Vec<f64>, Vec<f64>) {
        // Multi-pass equalization to get best quadbits (for equalization training)
        let (mut best_quadbits, mut best_scores) = self.correlate_all_blocks(descrambled_iq);
        let mut best_total: f64 = best_scores.iter().sum();
        let mut best_iq = None; // track equalized I/Q for final soft pass
        
        for _pass in 1..self.n_passes {
            let equalized = self.equalize_per_block(raw_iq, scramble_offsets, &best_quadbits);
            let desc_eq = self.descramble_with_offsets(&equalized, scramble_offsets);
            let (new_quadbits, new_scores) = self.correlate_all_blocks(&desc_eq);
            let new_total: f64 = new_scores.iter().sum();
            
            if new_total > best_total {
                best_quadbits = new_quadbits;
                best_scores = new_scores;
                best_total = new_total;
                best_iq = Some(desc_eq);
            }
        }
        
        // Final soft pass: compute LLRs on best equalized I/Q
        let final_iq = match &best_iq {
            Some(eq) => eq.as_slice(),
            None => descrambled_iq, // no equalization helped, use raw
        };
        
        let (_qbs, _scores, soft_bits) = self.correlate_all_blocks_soft(final_iq);
        
        (best_quadbits, best_scores, soft_bits)
    }
    
    /// Diagnostic decode: returns detailed per-block measurements.
    ///
    /// Returns: (quadbits, scores, soft_bits, diagnostics)
    /// where diagnostics is a Vec of per-block tuples:
    ///   (evm_raw, evm_eq, channel_tap_energy_ratio, residual_fit)
    ///
    /// evm_raw: EVM on raw I/Q (before equalization), in dB
    /// evm_eq: EVM on equalized I/Q, in dB  
    /// channel_tap_energy_ratio: |h[1]|² + |h[2]|² / |h[0]|²  (ISI strength)
    /// residual_fit: ||r - S*h||² / ||r||²  (how well channel model fits)
    pub fn decode_frame_diagnostic(
        &mut self,
        descrambled_iq: &[(f64, f64)],
        raw_iq: &[(f64, f64)],
        scramble_offsets: &[u8],
    ) -> (Vec<u8>, Vec<f64>, Vec<f64>, Vec<(f64, f64, f64, f64)>) {
        let n_blocks = descrambled_iq.len() / 64;
        let n_taps = 3usize;
        
        // First, run normal multi-pass decode to get best quadbits
        let (mut best_quadbits, mut best_scores) = self.correlate_all_blocks(descrambled_iq);
        let mut best_total: f64 = best_scores.iter().sum();
        let mut best_eq_iq = None;
        
        for _pass in 1..self.n_passes {
            let equalized = self.equalize_per_block(raw_iq, scramble_offsets, &best_quadbits);
            let desc_eq = self.descramble_with_offsets(&equalized, scramble_offsets);
            let (new_quadbits, new_scores) = self.correlate_all_blocks(&desc_eq);
            let new_total: f64 = new_scores.iter().sum();
            
            if new_total > best_total {
                best_quadbits = new_quadbits;
                best_scores = new_scores;
                best_total = new_total;
                best_eq_iq = Some((equalized, desc_eq));
            }
        }
        
        // Get soft bits from best I/Q
        let final_desc_iq = match &best_eq_iq {
            Some((_, desc)) => desc.as_slice(),
            None => descrambled_iq,
        };
        let (_qbs, _scores, soft_bits) = self.correlate_all_blocks_soft(final_desc_iq);
        
        // Now compute per-block diagnostics using the final quadbit decisions
        let mut diagnostics = Vec::with_capacity(n_blocks);
        
        for blk in 0..n_blocks {
            let start = blk * 64;
            let end = (start + 64).min(raw_iq.len());
            let blk_len = end - start;
            let qb = if blk < best_quadbits.len() { best_quadbits[blk] } else { 0 };
            let pattern = &self.walsh_signs[qb as usize];
            
            // Reconstruct expected tx I/Q
            let mut tx_i = [0.0f64; 64];
            let mut tx_q = [0.0f64; 64];
            for k in 0..blk_len {
                let idx = start + k;
                let descrambled_sym = if pattern[k] > 0.0 { 0u8 } else { 4u8 };
                let scrambled_sym = (descrambled_sym + scramble_offsets[idx]) % 8;
                let angle = scrambled_sym as f64 * std::f64::consts::PI / 4.0;
                tx_i[k] = angle.cos();
                tx_q[k] = angle.sin();
            }
            
            // Estimate 3-tap channel
            let mut sts_re = [[0.0f64; 3]; 3];
            let mut sts_im = [[0.0f64; 3]; 3];
            let mut str_re = [0.0f64; 3];
            let mut str_im = [0.0f64; 3];
            let mut rx_energy = 0.0f64;
            
            for row in 0..blk_len {
                let (ri, rq) = raw_iq[start + row];
                rx_energy += ri * ri + rq * rq;
                for j in 0..n_taps {
                    let nj = row as i32 - j as i32;
                    let (sj_i, sj_q) = if nj >= 0 && (nj as usize) < blk_len {
                        (tx_i[nj as usize], tx_q[nj as usize])
                    } else { (0.0, 0.0) };
                    str_re[j] += sj_i * ri + sj_q * rq;
                    str_im[j] += sj_i * rq - sj_q * ri;
                    for k in 0..n_taps {
                        let nk = row as i32 - k as i32;
                        let (sk_i, sk_q) = if nk >= 0 && (nk as usize) < blk_len {
                            (tx_i[nk as usize], tx_q[nk as usize])
                        } else { (0.0, 0.0) };
                        sts_re[j][k] += sj_i * sk_i + sj_q * sk_q;
                        sts_im[j][k] += sj_i * sk_q - sj_q * sk_i;
                    }
                }
            }
            
            // Regularize
            let reg = 0.1 * sts_re[0][0] / blk_len as f64;
            for j in 0..n_taps { sts_re[j][j] += reg.max(0.01); }
            
            let (h_re, h_im, isi_ratio, residual_fit) = 
                match solve_3x3_complex(&sts_re, &sts_im, &str_re, &str_im) {
                    Some((hr, hi)) => {
                        // ISI ratio: (|h1|² + |h2|²) / |h0|²
                        let h0_mag = hr[0] * hr[0] + hi[0] * hi[0];
                        let isi_mag = (hr[1] * hr[1] + hi[1] * hi[1]) + (hr[2] * hr[2] + hi[2] * hi[2]);
                        let isi_r = if h0_mag > 1e-10 { isi_mag / h0_mag } else { 0.0 };
                        
                        // Residual: ||r - S*h||² / ||r||²
                        let mut resid = 0.0f64;
                        for row in 0..blk_len {
                            let (ri, rq) = raw_iq[start + row];
                            let mut pred_i = 0.0f64;
                            let mut pred_q = 0.0f64;
                            for t in 0..n_taps {
                                let nt = row as i32 - t as i32;
                                if nt >= 0 && (nt as usize) < blk_len {
                                    pred_i += hr[t] * tx_i[nt as usize] - hi[t] * tx_q[nt as usize];
                                    pred_q += hr[t] * tx_q[nt as usize] + hi[t] * tx_i[nt as usize];
                                }
                            }
                            let ei = ri - pred_i;
                            let eq = rq - pred_q;
                            resid += ei * ei + eq * eq;
                        }
                        let resid_norm = if rx_energy > 1e-10 { resid / rx_energy } else { 1.0 };
                        
                        (hr, hi, isi_r, resid_norm)
                    }
                    None => ([0.0; 3], [0.0; 3], 0.0, 1.0)
                };
            
            // EVM on raw I/Q: compare raw descrambled to ideal (after 1-tap phase alignment)
            // Use h[0] as the phase/amplitude reference
            let h0_mag_sq = h_re[0] * h_re[0] + h_im[0] * h_im[0];
            let evm_raw = if h0_mag_sq > 0.001 {
                let mut error_power = 0.0f64;
                let mut sig_power = 0.0f64;
                for k in 0..blk_len {
                    // Ideal descrambled: pattern[k] as ±1 on I axis
                    let ideal_i = pattern[k]; // ±1
                    let ideal_q = 0.0f64;
                    // Received descrambled, normalized by h0
                    let (di, dq) = descrambled_iq[start + k];
                    let norm_i = (di * h_re[0] + dq * h_im[0]) / h0_mag_sq;
                    let norm_q = (dq * h_re[0] - di * h_im[0]) / h0_mag_sq;
                    let ei = norm_i - ideal_i;
                    let eq = norm_q - ideal_q;
                    error_power += ei * ei + eq * eq;
                    sig_power += ideal_i * ideal_i;
                }
                if sig_power > 0.0 { 10.0 * (error_power / sig_power).log10() } else { 0.0 }
            } else { 0.0 };
            
            // EVM on equalized I/Q
            let evm_eq = match &best_eq_iq {
                Some((_, desc_eq)) if start + blk_len <= desc_eq.len() => {
                    let mut error_power = 0.0f64;
                    let mut sig_power = 0.0f64;
                    for k in 0..blk_len {
                        let ideal_i = pattern[k];
                        let (di, dq) = desc_eq[start + k];
                        // After equalization, should be close to ideal already
                        let ei = di - ideal_i;
                        let eq_val = dq - 0.0;
                        error_power += ei * ei + eq_val * eq_val;
                        sig_power += ideal_i * ideal_i;
                    }
                    if sig_power > 0.0 { 10.0 * (error_power / sig_power).log10() } else { 0.0 }
                }
                _ => evm_raw // no equalization happened
            };
            
            diagnostics.push((evm_raw, evm_eq, isi_ratio, residual_fit));
        }
        
        (best_quadbits, best_scores, soft_bits, diagnostics)
    }
    
    pub(crate) fn correlate_all_blocks(&mut self, iq: &[(f64, f64)]) -> (Vec<u8>, Vec<f64>) {
        let n_blocks = iq.len() / 64;
        let mut quadbits = Vec::with_capacity(n_blocks);
        let mut scores = Vec::with_capacity(n_blocks);
        
        for blk in 0..n_blocks {
            let start = blk * 64;
            let end = start + 64;
            if end <= iq.len() {
                let (qb, score, _phase, _) = self.correlate_block(&iq[start..end]);
                quadbits.push(qb);
                scores.push(score);
            }
        }
        
        (quadbits, scores)
    }
    
    /// Correlate all blocks, returning soft bit LLRs for each block.
    /// Returns (quadbits, scores, soft_bits) where soft_bits is 4 LLRs per block.
    fn correlate_all_blocks_soft(&mut self, iq: &[(f64, f64)]) -> (Vec<u8>, Vec<f64>, Vec<f64>) {
        let n_blocks = iq.len() / 64;
        let mut quadbits = Vec::with_capacity(n_blocks);
        let mut scores = Vec::with_capacity(n_blocks);
        let mut soft_bits = Vec::with_capacity(n_blocks * 4);
        
        for blk in 0..n_blocks {
            let start = blk * 64;
            let end = start + 64;
            if end <= iq.len() {
                let (qb, score, _phase, all_scores) = self.correlate_block(&iq[start..end]);
                quadbits.push(qb);
                scores.push(score);
                
                // Compute per-bit LLRs from the 16 candidate scores.
                //
                // The raw LLR = max(scores where b=1) - max(scores where b=0)
                // is in correlation units that scale with signal amplitude.
                //
                // We need to normalize so that:
                // - High-quality blocks (score≈64) get large |LLR| → confident
                // - Low-quality blocks (score≈40) get small |LLR| → uncertain
                //
                // Normalization: divide by the sum of the two best competing
                // scores. This gives a value in [0, 1] range, then scale to
                // a reasonable LLR range.
                //
                // Alternative: use the winning score as a quality indicator.
                // LLR_scaled = LLR_raw × (score/64)² 
                // This makes reliability proportional to block SNR.
                
                let quality = (score / 64.0).powi(2).clamp(0.01, 1.0);
                
                for bit_pos in (0..4).rev() {
                    let mask = 1u8 << bit_pos;
                    let mut max_1 = f64::NEG_INFINITY;
                    let mut max_0 = f64::NEG_INFINITY;
                    for q in 0..16u8 {
                        if (q & mask) != 0 {
                            if all_scores[q as usize] > max_1 { max_1 = all_scores[q as usize]; }
                        } else {
                            if all_scores[q as usize] > max_0 { max_0 = all_scores[q as usize]; }
                        }
                    }
                    
                    // Normalize: divide by sum of competing scores to get
                    // a contrast ratio, then scale by block quality
                    let denom = (max_1.abs() + max_0.abs()).max(0.01);
                    let llr_raw = (max_1 - max_0) / denom; // in [-1, 1]
                    let llr = (llr_raw * quality * 8.0).clamp(-4.0, 4.0);
                    soft_bits.push(llr);
                }
            }
        }
        
        (quadbits, scores, soft_bits)
    }
    
    /// Correlate a single 64-chip block with linear phase tracking.
    ///
    /// Two-pass approach:
    ///   Pass 1: Find best (phase, quadbit) with constant phase (as before)
    ///   Pass 2: Using winning quadbit, estimate linear phase slope across
    ///           the block, derotate, then re-score all 16 candidates.
    ///
    /// Returns (quadbit, soft_score, phase, best_score_per_candidate[16]).
    fn correlate_block(&mut self, iq: &[(f64, f64)]) -> (u8, f64, f64, [f64; 16]) {
        let mut best_qb = 0u8;
        let mut best_score = f64::NEG_INFINITY;
        let mut best_phase = 0.0f64;
        let mut best_phase_idx = 0usize;
        
        // Track the best score for EACH of the 16 candidates across all phases
        let mut candidate_best = [f64::NEG_INFINITY; 16];
        
        // ── Pass 1: constant-phase search (same as before) ──
        for ph in 0..self.n_phases {
            let cos_t = self.phase_cos[ph];
            let sin_t = self.phase_sin[ph];
            
            for k in 0..64 {
                self.rot_i[k] = iq[k].0 * cos_t + iq[k].1 * sin_t;
            }
            
            for qb in 0..16usize {
                let signs = &self.walsh_signs[qb];
                let mut score = 0.0f64;
                for k in 0..64 {
                    score += self.rot_i[k] * signs[k];
                }
                if score > candidate_best[qb] {
                    candidate_best[qb] = score;
                }
                if score > best_score {
                    best_score = score;
                    best_qb = qb as u8;
                    best_phase = ph as f64 * PI / self.n_phases as f64;
                    best_phase_idx = ph;
                }
            }
        }
        
        // ── Pass 2: linear phase derotation ──
        // Using the winning quadbit from Pass 1, estimate how the phase
        // drifts across the 64 symbols, then derotate and re-correlate.
        //
        // Split block into two halves (0..31 and 32..63).
        // Find best phase for each half using the winning quadbit.
        // Interpolate linearly across the block.
        
        let signs_winner = &self.walsh_signs[best_qb as usize];
        
        // Find best phase for first half
        let mut best_ph1 = best_phase_idx;
        let mut best_sc1 = f64::NEG_INFINITY;
        for ph in 0..self.n_phases {
            let cos_t = self.phase_cos[ph];
            let sin_t = self.phase_sin[ph];
            let mut sc = 0.0f64;
            for k in 0..32 {
                let ri = iq[k].0 * cos_t + iq[k].1 * sin_t;
                sc += ri * signs_winner[k];
            }
            if sc > best_sc1 {
                best_sc1 = sc;
                best_ph1 = ph;
            }
        }
        
        // Find best phase for second half
        let mut best_ph2 = best_phase_idx;
        let mut best_sc2 = f64::NEG_INFINITY;
        for ph in 0..self.n_phases {
            let cos_t = self.phase_cos[ph];
            let sin_t = self.phase_sin[ph];
            let mut sc = 0.0f64;
            for k in 32..64 {
                let ri = iq[k].0 * cos_t + iq[k].1 * sin_t;
                sc += ri * signs_winner[k];
            }
            if sc > best_sc2 {
                best_sc2 = sc;
                best_ph2 = ph;
            }
        }
        
        // Convert phase indices to radians
        let phase1 = best_ph1 as f64 * PI / self.n_phases as f64;
        let phase2 = best_ph2 as f64 * PI / self.n_phases as f64;
        
        // Only apply linear derotation if there's meaningful phase drift
        let phase_diff = phase2 - phase1;
        // Wrap to [-π/2, π/2] to avoid ambiguity
        let phase_diff = if phase_diff > PI / 2.0 { phase_diff - PI }
                         else if phase_diff < -PI / 2.0 { phase_diff + PI }
                         else { phase_diff };
        
        if phase_diff.abs() > 0.02 {
            // Significant drift detected — derotate and re-score
            // Phase at symbol k: phase1 + (k - 16) * phase_diff / 32
            // (centered: phase1 is at k=16, phase2 at k=48, slope = phase_diff/32)
            let slope = phase_diff / 32.0;
            let phase_center = (phase1 + phase2) / 2.0;
            
            // Derotate each symbol by its interpolated phase
            let mut derot_iq = [(0.0f64, 0.0f64); 64];
            for k in 0..64 {
                let ph_k = phase_center + (k as f64 - 31.5) * slope;
                let cos_k = ph_k.cos();
                let sin_k = ph_k.sin();
                derot_iq[k] = (
                    iq[k].0 * cos_k + iq[k].1 * sin_k,
                    iq[k].1 * cos_k - iq[k].0 * sin_k,
                );
            }
            
            // Re-correlate all 16 candidates on derotated I/Q (I component only)
            let mut derot_candidate_best = [f64::NEG_INFINITY; 16];
            let mut derot_best_qb = best_qb;
            let mut derot_best_score = f64::NEG_INFINITY;
            
            for qb in 0..16usize {
                let signs = &self.walsh_signs[qb];
                let mut score = 0.0f64;
                for k in 0..64 {
                    score += derot_iq[k].0 * signs[k];
                }
                derot_candidate_best[qb] = score;
                if score > derot_best_score {
                    derot_best_score = score;
                    derot_best_qb = qb as u8;
                }
            }
            
            // Use derotated results if they're better
            if derot_best_score > best_score {
                best_qb = derot_best_qb;
                best_score = derot_best_score;
                best_phase = phase_center;
                candidate_best = derot_candidate_best;
            }
        }
        
        // Compute hard score for compatibility
        let cos_t = best_phase.cos();
        let sin_t = best_phase.sin();
        let signs = &self.walsh_signs[best_qb as usize];
        let mut hard_correct = 0u32;
        for k in 0..64 {
            let ri = iq[k].0 * cos_t + iq[k].1 * sin_t;
            let rx_sign = if ri >= 0.0 { 1.0 } else { -1.0 };
            if rx_sign == signs[k] {
                hard_correct += 1;
            }
        }
        
        (best_qb, hard_correct as f64, best_phase, candidate_best)
    }
    
    // ════════════════════════════════════════════════════════════════
    // Per-block equalization
    // ════════════════════════════════════════════════════════════════
    
    /// Multi-tap MMSE equalization per 64-symbol block.
    ///
    /// For each block:
    /// 1. Reconstruct expected transmitted I/Q from Walsh decisions
    /// 2. Estimate 3-tap complex channel: r[n] = h0*s[n] + h1*s[n-1] + h2*s[n-2]
    /// 3. Apply MMSE inverse filter to remove ISI
    pub(crate) fn equalize_per_block(
        &self,
        raw_iq: &[(f64, f64)],
        scramble_offsets: &[u8],
        quadbits: &[u8],
    ) -> Vec<(f64, f64)> {
        let n = raw_iq.len();
        let mut output = Vec::with_capacity(n);
        let n_blocks = n / 64;
        let n_taps = 3usize; // channel taps to model
        
        for blk in 0..n_blocks {
            let start = blk * 64;
            let end = (start + 64).min(n);
            let blk_len = end - start;
            let qb = if blk < quadbits.len() { quadbits[blk] } else { 0 };
            let pattern = &self.walsh_signs[qb as usize];
            
            // Reconstruct expected tx I/Q for this block
            let mut tx_i = [0.0f64; 64];
            let mut tx_q = [0.0f64; 64];
            for k in 0..blk_len {
                let idx = start + k;
                let descrambled_sym = if pattern[k] > 0.0 { 0u8 } else { 4u8 };
                let scrambled_sym = (descrambled_sym + scramble_offsets[idx]) % 8;
                let angle = scrambled_sym as f64 * PI / 4.0;
                tx_i[k] = angle.cos();
                tx_q[k] = angle.sin();
            }
            
            // Estimate channel by least-squares: r = S*h
            // S is (blk_len × n_taps), S[n][k] = s[n-k] (complex)
            // Normal equations: (S'S) h = S'r  (all complex)
            // S'S is n_taps × n_taps, S'r is n_taps × 1
            
            // Compute S'S (complex hermitian) and S'r (complex)
            let mut sts_re = [[0.0f64; 3]; 3];
            let mut sts_im = [[0.0f64; 3]; 3];
            let mut str_re = [0.0f64; 3];
            let mut str_im = [0.0f64; 3];
            
            for row in 0..blk_len {
                let (ri, rq) = raw_iq[start + row];
                for j in 0..n_taps {
                    let nj = row as i32 - j as i32;
                    let (sj_i, sj_q) = if nj >= 0 && (nj as usize) < blk_len {
                        (tx_i[nj as usize], tx_q[nj as usize])
                    } else { (0.0, 0.0) };
                    
                    // S'r: conj(s[n-j]) * r[n]
                    str_re[j] += sj_i * ri + sj_q * rq;
                    str_im[j] += sj_i * rq - sj_q * ri;
                    
                    for k in 0..n_taps {
                        let nk = row as i32 - k as i32;
                        let (sk_i, sk_q) = if nk >= 0 && (nk as usize) < blk_len {
                            (tx_i[nk as usize], tx_q[nk as usize])
                        } else { (0.0, 0.0) };
                        
                        // S'S: conj(s[n-j]) * s[n-k]
                        sts_re[j][k] += sj_i * sk_i + sj_q * sk_q;
                        sts_im[j][k] += sj_i * sk_q - sj_q * sk_i;
                    }
                }
            }
            
            // Add regularization (MMSE): S'S + σ²I
            // σ² estimated from noise. Use small value relative to signal.
            let reg = 0.1 * sts_re[0][0] / blk_len as f64;
            for j in 0..n_taps {
                sts_re[j][j] += reg.max(0.01);
            }
            
            // Solve 3×3 complex system by Gaussian elimination
            match solve_3x3_complex(&sts_re, &sts_im, &str_re, &str_im) {
                Some((h_re, h_im)) => {
                    // Apply zero-forcing: for each sample, subtract ISI from delayed taps
                    // r_eq[n] = (r[n] - h1*s[n-1] - h2*s[n-2]) / h0
                    let h0_mag_sq = h_re[0] * h_re[0] + h_im[0] * h_im[0];
                    if h0_mag_sq > 0.001 {
                        for k in 0..blk_len {
                            let (ri, rq) = raw_iq[start + k];
                            
                            // Subtract ISI from known symbols
                            let mut isi_i = 0.0f64;
                            let mut isi_q = 0.0f64;
                            for tap in 1..n_taps {
                                let prev = k as i32 - tap as i32;
                                if prev >= 0 && (prev as usize) < blk_len {
                                    let (si, sq) = (tx_i[prev as usize], tx_q[prev as usize]);
                                    // h[tap] * s[n-tap]
                                    isi_i += h_re[tap] * si - h_im[tap] * sq;
                                    isi_q += h_re[tap] * sq + h_im[tap] * si;
                                }
                            }
                            
                            // Remove ISI and divide by h0
                            let clean_i = ri - isi_i;
                            let clean_q = rq - isi_q;
                            // r_eq = clean * conj(h0) / |h0|²
                            let eq_i = (clean_i * h_re[0] + clean_q * h_im[0]) / h0_mag_sq;
                            let eq_q = (clean_q * h_re[0] - clean_i * h_im[0]) / h0_mag_sq;
                            output.push((eq_i, eq_q));
                        }
                    } else {
                        for k in 0..blk_len { output.push(raw_iq[start + k]); }
                    }
                }
                None => {
                    // Singular — pass through raw
                    for k in 0..blk_len { output.push(raw_iq[start + k]); }
                }
            }
        }
        
        for i in (n_blocks * 64)..n {
            output.push(raw_iq[i]);
        }
        
        output
    }
    
    /// Descramble I/Q by rotating by -offset*π/4
    pub(crate) fn descramble_with_offsets(
        &self,
        iq: &[(f64, f64)],
        scramble_offsets: &[u8],
    ) -> Vec<(f64, f64)> {
        iq.iter()
            .zip(scramble_offsets.iter())
            .map(|(&(i, q), &offset)| {
                if offset == 0 {
                    (i, q)
                } else {
                    let angle = -(offset as f64) * PI / 4.0;
                    let (cos_a, sin_a) = (angle.cos(), angle.sin());
                    (i * cos_a - q * sin_a, i * sin_a + q * cos_a)
                }
            })
            .collect()
    }
    
    /// Estimate channel for a single block (for telemetry)
    fn estimate_channel_block(
        &self,
        raw_block: &[(f64, f64)],
        scramble_offsets: &[u8],
        start_idx: usize,
        qb: u8,
    ) -> (f64, f64) {
        let pattern = &self.walsh_signs[qb as usize];
        let mut h_re = 0.0f64;
        let mut h_im = 0.0f64;
        let mut s_energy = 0.0f64;
        
        for k in 0..raw_block.len().min(64) {
            let (ri, rq) = raw_block[k];
            let descrambled_sym = if pattern[k] > 0.0 { 0u8 } else { 4u8 };
            let scrambled_sym = (descrambled_sym + scramble_offsets[start_idx + k]) % 8;
            let angle = scrambled_sym as f64 * PI / 4.0;
            let (si, sq) = (angle.cos(), angle.sin());
            
            h_re += ri * si + rq * sq;
            h_im += rq * si - ri * sq;
            s_energy += si * si + sq * sq;
        }
        
        if s_energy > 0.01 {
            h_re /= s_energy;
            h_im /= s_energy;
            let mag = (h_re * h_re + h_im * h_im).sqrt();
            let phase = h_im.atan2(h_re);
            (mag, phase)
        } else {
            (0.0, 0.0)
        }
    }
}

/// Solve a 3×3 complex linear system Ax = b using Cramer's rule.
/// A is given as separate real and imaginary parts.
/// Returns Some((x_re, x_im)) or None if singular.
fn solve_3x3_complex(
    a_re: &[[f64; 3]; 3],
    a_im: &[[f64; 3]; 3],
    b_re: &[f64; 3],
    b_im: &[f64; 3],
) -> Option<([f64; 3], [f64; 3])> {
    // Use Gaussian elimination with partial pivoting for 3×3 complex system
    // Augmented matrix: [A | b] as 3×4 complex
    let mut m_re = [[0.0f64; 4]; 3];
    let mut m_im = [[0.0f64; 4]; 3];
    
    for i in 0..3 {
        for j in 0..3 {
            m_re[i][j] = a_re[i][j];
            m_im[i][j] = a_im[i][j];
        }
        m_re[i][3] = b_re[i];
        m_im[i][3] = b_im[i];
    }
    
    // Forward elimination with partial pivoting
    for col in 0..3 {
        // Find pivot (largest magnitude)
        let mut best_row = col;
        let mut best_mag = m_re[col][col] * m_re[col][col] + m_im[col][col] * m_im[col][col];
        for row in (col + 1)..3 {
            let mag = m_re[row][col] * m_re[row][col] + m_im[row][col] * m_im[row][col];
            if mag > best_mag {
                best_mag = mag;
                best_row = row;
            }
        }
        
        if best_mag < 1e-20 { return None; }
        
        // Swap rows
        if best_row != col {
            for j in 0..4 {
                let tmp_re = m_re[col][j]; m_re[col][j] = m_re[best_row][j]; m_re[best_row][j] = tmp_re;
                let tmp_im = m_im[col][j]; m_im[col][j] = m_im[best_row][j]; m_im[best_row][j] = tmp_im;
            }
        }
        
        // Eliminate below
        for row in (col + 1)..3 {
            // factor = m[row][col] / m[col][col]  (complex division)
            let pr = m_re[col][col]; let pi = m_im[col][col];
            let nr = m_re[row][col]; let ni = m_im[row][col];
            let denom = pr * pr + pi * pi;
            let fr = (nr * pr + ni * pi) / denom;
            let fi = (ni * pr - nr * pi) / denom;
            
            for j in col..4 {
                // m[row][j] -= factor * m[col][j]
                m_re[row][j] -= fr * m_re[col][j] - fi * m_im[col][j];
                m_im[row][j] -= fr * m_im[col][j] + fi * m_re[col][j];
            }
        }
    }
    
    // Back substitution
    let mut x_re = [0.0f64; 3];
    let mut x_im = [0.0f64; 3];
    
    for i in (0..3).rev() {
        let mut sr = m_re[i][3];
        let mut si = m_im[i][3];
        for j in (i + 1)..3 {
            // s -= m[i][j] * x[j]
            sr -= m_re[i][j] * x_re[j] - m_im[i][j] * x_im[j];
            si -= m_re[i][j] * x_im[j] + m_im[i][j] * x_re[j];
        }
        // x[i] = s / m[i][i]
        let pr = m_re[i][i]; let pi = m_im[i][i];
        let denom = pr * pr + pi * pi;
        if denom < 1e-20 { return None; }
        x_re[i] = (sr * pr + si * pi) / denom;
        x_im[i] = (si * pr - sr * pi) / denom;
    }
    
    Some((x_re, x_im))
}
