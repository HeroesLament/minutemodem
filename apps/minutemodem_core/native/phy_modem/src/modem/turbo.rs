//! Turbo (iterative) decoder for Walsh-coded convolutional systems.
//!
//! Implements iterative decoding between the Walsh demodulator and a
//! BCJR (MAP) convolutional decoder. Each iteration:
//!
//!   1. Walsh correlator produces intrinsic LLRs from I/Q correlation
//!   2. Deinterleave → BCJR produces extrinsic LLRs about each coded bit
//!   3. Re-interleave extrinsic info → feed back as priors to Walsh correlator
//!   4. Walsh correlator re-scores blocks using intrinsic + extrinsic
//!
//! The BCJR algorithm computes exact APP (a posteriori probability) for
//! each bit position, unlike the standard Viterbi which only finds the
//! ML path. The "extrinsic" information (what the code constraints tell
//! us about each bit, beyond what we already knew from the channel) is
//! the key to turbo gain.
//!
//! Convolutional code: rate 1/2, K=7, G1=0b1011011 (0x5B), G2=0b1111001 (0x79)
//! 64 states, terminated (flush to zero state).
//!
//! Interleaver: 12×16 block interleaver (192 soft dibits = 384 coded bits).
//! Walsh: 96 blocks × 4 bits/block = 384 coded bits.

use std::f64;

// ============================================================================
// Convolutional code parameters
// ============================================================================

const K: usize = 7;                    // Constraint length
const NUM_STATES: usize = 64;          // 2^(K-1)
const G1: u8 = 0x5B;                   // Generator polynomial 1: 1011011
const G2: u8 = 0x79;                   // Generator polynomial 2: 1111001

// Numerical limits for log-domain BCJR
const LOG_ZERO: f64 = -1e10;           // Represents -infinity in log domain
const LLR_CLIP: f64 = 20.0;           // Clip extrinsic LLRs to prevent runaway

// ============================================================================
// Trellis structure (precomputed)
// ============================================================================

/// One trellis branch: from prev_state, input bit → next_state, output (c1, c2)
#[derive(Clone, Copy)]
struct TrellisBranch {
    prev_state: u8,
    next_state: u8,
    input: u8,
    output_c1: u8,        // First coded bit
    output_c2: u8,        // Second coded bit
}

/// Precomputed trellis for the rate 1/2 K=7 code.
/// For each state, there are exactly 2 outgoing branches (input=0 and input=1).
struct Trellis {
    /// branches[state][input] = TrellisBranch
    branches: [[TrellisBranch; 2]; NUM_STATES],
    /// Reverse lookup: for each state, which (prev_state, input) pairs lead here?
    /// reverse[next_state] = Vec<(prev_state, input)>
    reverse: [Vec<(u8, u8)>; NUM_STATES],
}

impl Trellis {
    fn new() -> Self {
        let mut branches = [[TrellisBranch {
            prev_state: 0, next_state: 0, input: 0, output_c1: 0, output_c2: 0,
        }; 2]; NUM_STATES];

        // Build array of empty Vecs for reverse lookup
        let mut reverse: [Vec<(u8, u8)>; NUM_STATES] = std::array::from_fn(|_| Vec::new());

        for state in 0..NUM_STATES {
            for input in 0u8..2 {
                let next_state = ((state << 1) | (input as usize)) & (NUM_STATES - 1);
                let reg = (state << 1) | (input as usize);
                let c1 = (reg & (G1 as usize)).count_ones() as u8 & 1;
                let c2 = (reg & (G2 as usize)).count_ones() as u8 & 1;

                branches[state][input as usize] = TrellisBranch {
                    prev_state: state as u8,
                    next_state: next_state as u8,
                    input,
                    output_c1: c1,
                    output_c2: c2,
                };

                reverse[next_state].push((state as u8, input));
            }
        }

        Trellis { branches, reverse }
    }
}

// ============================================================================
// BCJR (MAP) Decoder
// ============================================================================

/// BCJR decoder for rate 1/2, K=7 convolutional code.
///
/// Takes channel LLRs for each coded dibit and optional a priori LLRs
/// for each information bit. Returns extrinsic LLRs for each information bit.
pub struct BcjrDecoder {
    trellis: Trellis,
}

impl BcjrDecoder {
    pub fn new() -> Self {
        BcjrDecoder {
            trellis: Trellis::new(),
        }
    }

    /// Run BCJR on a sequence of coded dibits.
    ///
    /// # Arguments
    /// * `channel_llrs` - Channel LLRs as (llr_c1, llr_c2) per coded dibit.
    ///   Positive = bit more likely 1. Length = number of trellis steps.
    /// * `apriori_llrs` - A priori LLRs on each information bit (from previous
    ///   iteration's extrinsic output). Length = number of trellis steps.
    ///   Pass all-zeros for the first iteration.
    ///
    /// # Returns
    /// * `extrinsic_llrs` - Extrinsic LLRs for each information bit.
    ///   This is APP - channel - apriori, i.e. purely what the code tells us.
    /// * `hard_bits` - Hard decisions from APP LLRs.
    pub fn decode(
        &self,
        channel_llrs: &[(f64, f64)],
        apriori_llrs: &[f64],
    ) -> (Vec<f64>, Vec<u8>) {
        let n_steps = channel_llrs.len();
        if n_steps == 0 {
            return (vec![], vec![]);
        }

        // Forward metrics (alpha): alpha[t][s] = log P(state_t = s, y_1..t)
        // Backward metrics (beta): beta[t][s] = log P(y_t+1..T | state_t = s)
        let mut alpha = vec![[LOG_ZERO; NUM_STATES]; n_steps + 1];
        let mut beta = vec![[LOG_ZERO; NUM_STATES]; n_steps + 1];

        // Initialize: start in state 0
        alpha[0][0] = 0.0;

        // Initialize: terminated in state 0
        beta[n_steps][0] = 0.0;

        // ── Forward pass ──
        for t in 0..n_steps {
            let (llr_c1, llr_c2) = channel_llrs[t];
            let apriori = if t < apriori_llrs.len() { apriori_llrs[t] } else { 0.0 };

            for state in 0..NUM_STATES {
                if alpha[t][state] <= LOG_ZERO + 1.0 {
                    continue;  // Unreachable state
                }

                for input in 0u8..2 {
                    let br = &self.trellis.branches[state][input as usize];
                    let next = br.next_state as usize;

                    // Branch metric = log P(y_t | c1,c2) + log P(input)
                    // For BPSK mapping: P(y|c) uses LLR directly
                    // gamma = input*apriori + c1*llr_c1 + c2*llr_c2
                    // (with sign convention: LLR>0 means bit=1 more likely)
                    let gamma = branch_metric(br.input, br.output_c1, br.output_c2,
                                              llr_c1, llr_c2, apriori);

                    alpha[t + 1][next] = log_add(alpha[t + 1][next],
                                                  alpha[t][state] + gamma);
                }
            }

            // Normalize alpha to prevent overflow
            let max_alpha = alpha[t + 1].iter().cloned().fold(LOG_ZERO, f64::max);
            if max_alpha > LOG_ZERO + 1.0 {
                for s in 0..NUM_STATES {
                    alpha[t + 1][s] -= max_alpha;
                }
            }
        }

        // ── Backward pass ──
        for t in (0..n_steps).rev() {
            let (llr_c1, llr_c2) = channel_llrs[t];
            let apriori = if t < apriori_llrs.len() { apriori_llrs[t] } else { 0.0 };

            for next_state in 0..NUM_STATES {
                if beta[t + 1][next_state] <= LOG_ZERO + 1.0 {
                    continue;
                }

                for &(prev_state, input) in &self.trellis.reverse[next_state] {
                    let br = &self.trellis.branches[prev_state as usize][input as usize];

                    let gamma = branch_metric(br.input, br.output_c1, br.output_c2,
                                              llr_c1, llr_c2, apriori);

                    beta[t][prev_state as usize] = log_add(
                        beta[t][prev_state as usize],
                        beta[t + 1][next_state] + gamma,
                    );
                }
            }

            // Normalize beta
            let max_beta = beta[t].iter().cloned().fold(LOG_ZERO, f64::max);
            if max_beta > LOG_ZERO + 1.0 {
                for s in 0..NUM_STATES {
                    beta[t][s] -= max_beta;
                }
            }
        }

        // ── Compute APP LLRs for each information bit ──
        let mut extrinsic = Vec::with_capacity(n_steps);
        let mut hard_bits = Vec::with_capacity(n_steps);

        for t in 0..n_steps {
            let (llr_c1, llr_c2) = channel_llrs[t];
            let apriori = if t < apriori_llrs.len() { apriori_llrs[t] } else { 0.0 };

            // Sum over all transitions with input=1 vs input=0
            let mut log_p1 = LOG_ZERO;  // log P(input_t = 1 | y)
            let mut log_p0 = LOG_ZERO;  // log P(input_t = 0 | y)

            for state in 0..NUM_STATES {
                if alpha[t][state] <= LOG_ZERO + 1.0 {
                    continue;
                }

                for input in 0u8..2 {
                    let br = &self.trellis.branches[state][input as usize];
                    let next = br.next_state as usize;

                    if beta[t + 1][next] <= LOG_ZERO + 1.0 {
                        continue;
                    }

                    let gamma = branch_metric(br.input, br.output_c1, br.output_c2,
                                              llr_c1, llr_c2, apriori);

                    let metric = alpha[t][state] + gamma + beta[t + 1][next];

                    if input == 1 {
                        log_p1 = log_add(log_p1, metric);
                    } else {
                        log_p0 = log_add(log_p0, metric);
                    }
                }
            }

            // APP LLR for information bit
            let app_llr = log_p1 - log_p0;

            // Extrinsic = APP - channel contribution to info bit - apriori
            // The channel doesn't directly tell us about the info bit (only coded bits),
            // so extrinsic = APP - apriori
            let ext = (app_llr - apriori).clamp(-LLR_CLIP, LLR_CLIP);

            extrinsic.push(ext);
            hard_bits.push(if app_llr >= 0.0 { 1u8 } else { 0u8 });
        }

        (extrinsic, hard_bits)
    }
}

/// Branch metric in log domain.
///
/// gamma = input * L_a + c1_sign * L_c1 + c2_sign * L_c2
///
/// where c_sign = +1 if c=1, -1 if c=0 (maps {0,1} to {-1,+1}/2)
/// This gives: log P(y|c) ∝ c * L/2 for each coded bit.
#[inline]
fn branch_metric(input: u8, c1: u8, c2: u8, llr_c1: f64, llr_c2: f64, apriori: f64) -> f64 {
    // Map bit {0,1} to sign {-0.5, +0.5}
    let s_input = if input == 1 { 0.5 } else { -0.5 };
    let s_c1 = if c1 == 1 { 0.5 } else { -0.5 };
    let s_c2 = if c2 == 1 { 0.5 } else { -0.5 };

    s_input * apriori + s_c1 * llr_c1 + s_c2 * llr_c2
}

/// Log-domain addition: log(exp(a) + exp(b))
/// Uses the Jacobian: max(a,b) + log(1 + exp(-|a-b|))
#[inline]
fn log_add(a: f64, b: f64) -> f64 {
    if a <= LOG_ZERO + 1.0 {
        return b;
    }
    if b <= LOG_ZERO + 1.0 {
        return a;
    }
    let max = if a > b { a } else { b };
    let diff = (a - b).abs();
    if diff > 37.0 {
        // exp(-37) ≈ 0, skip the log1p
        max
    } else {
        max + (-diff).exp().ln_1p()
    }
}

// ============================================================================
// Interleaver (12×16 block, matching Elixir Encoding.interleave/deinterleave)
// ============================================================================

const INTERLEAVER_ROWS: usize = 12;
const INTERLEAVER_COLS: usize = 16;
const INTERLEAVER_SIZE: usize = INTERLEAVER_ROWS * INTERLEAVER_COLS; // 192

/// Compute the deinterleave permutation: maps interleaved index → original index.
/// Elixir interleave: write row-by-row, read column-by-column.
/// Deinterleave: write column-by-column, read row-by-row.
fn deinterleave_permutation() -> [usize; INTERLEAVER_SIZE] {
    let mut perm = [0usize; INTERLEAVER_SIZE];
    let mut idx = 0;
    // Deinterleave reads row-by-row from a matrix written column-by-column
    for row in 0..INTERLEAVER_ROWS {
        for col in 0..INTERLEAVER_COLS {
            // The interleaved position for (row, col) is col * ROWS + row
            perm[idx] = col * INTERLEAVER_ROWS + row;
            idx += 1;
        }
    }
    perm
}

/// Compute the interleave permutation (inverse of deinterleave).
fn interleave_permutation() -> [usize; INTERLEAVER_SIZE] {
    let deint = deinterleave_permutation();
    let mut perm = [0usize; INTERLEAVER_SIZE];
    for (i, &j) in deint.iter().enumerate() {
        perm[j] = i;
    }
    perm
}

/// Apply a permutation to a slice of LLR pairs (soft dibits).
fn permute_dibit_llrs(llrs: &[(f64, f64)], perm: &[usize; INTERLEAVER_SIZE]) -> Vec<(f64, f64)> {
    let n = llrs.len().min(INTERLEAVER_SIZE);
    let mut out = vec![(0.0, 0.0); n];
    for i in 0..n {
        let src = perm[i];
        if src < llrs.len() {
            out[i] = llrs[src];
        }
    }
    out
}

/// Apply a permutation to a slice of single LLR values.
fn permute_llrs(llrs: &[f64], perm: &[usize; INTERLEAVER_SIZE]) -> Vec<f64> {
    let n = llrs.len().min(INTERLEAVER_SIZE);
    let mut out = vec![0.0; n];
    for i in 0..n {
        let src = perm[i];
        if src < llrs.len() {
            out[i] = llrs[src];
        }
    }
    out
}

// ============================================================================
// Turbo decoder: iterative Walsh ↔ BCJR
// ============================================================================

/// Turbo decode a Deep WALE frame.
///
/// This is the main entry point. It takes the equalized I/Q from the
/// Walsh DFE and runs iterative decoding between the Walsh correlator
/// and the BCJR decoder.
///
/// # Arguments
/// * `correlator` - Walsh correlator (for re-scoring blocks with priors)
/// * `equalized_iq` - Best equalized & descrambled I/Q from DFE (96 blocks × 64 chips)
/// * `n_iterations` - Number of turbo iterations (typically 2-4)
///
/// # Returns
/// * `hard_bits` - Decoded information bits
/// * `soft_llrs` - Final APP LLRs for each coded dibit (for metric extraction)
/// * `extrinsic_llrs` - Final extrinsic info (for diagnostics)
/// * `iteration_scores` - Total Walsh correlation score per iteration (convergence tracking)
pub fn turbo_decode(
    walsh_signs: &[[f64; 64]; 16],
    equalized_iq: &[(f64, f64)],
    n_phases: usize,
    n_iterations: usize,
) -> (Vec<u8>, Vec<(f64, f64)>, Vec<f64>, Vec<f64>) {
    let n_blocks = equalized_iq.len() / 64;
    let bcjr = BcjrDecoder::new();
    let deint_perm = deinterleave_permutation();
    let int_perm = interleave_permutation();

    // Precompute trig tables for phase search
    let phase_cos: Vec<f64> = (0..n_phases)
        .map(|k| (k as f64 * std::f64::consts::PI / n_phases as f64).cos())
        .collect();
    let phase_sin: Vec<f64> = (0..n_phases)
        .map(|k| (k as f64 * std::f64::consts::PI / n_phases as f64).sin())
        .collect();

    // Initial Walsh decode: no priors
    let (mut intrinsic_llrs, mut total_score) = walsh_soft_with_priors(
        walsh_signs, equalized_iq, &phase_cos, &phase_sin, None, n_blocks,
    );

    let mut iteration_scores = vec![total_score];
    let mut extrinsic_info_bits: Vec<f64> = vec![0.0; n_blocks]; // info bits, not coded bits

    // Extrinsic feedback in Walsh domain (384 coded bit LLRs, as 192 dibit pairs)
    let mut walsh_priors: Option<Vec<(f64, f64)>> = None;

    for _iter in 0..n_iterations {
        // 1. Deinterleave the intrinsic LLRs (soft dibits)
        let deinterleaved = permute_dibit_llrs(&intrinsic_llrs, &deint_perm);

        // 2. Convert soft dibits to channel LLR pairs for BCJR
        //    Each dibit {llr1, llr2} maps to coded bits (c1, c2) at one trellis step
        let channel_llrs: Vec<(f64, f64)> = deinterleaved.iter().copied().collect();

        // 3. Run BCJR with a priori info from previous iteration
        let (extrinsic, hard_bits) = bcjr.decode(&channel_llrs, &extrinsic_info_bits);
        extrinsic_info_bits = extrinsic;

        // 4. Convert extrinsic info on INFO bits back to extrinsic on CODED bits
        //    The BCJR gives us L_e(u_t) for each info bit. We need to propagate
        //    this back to the coded bits that depend on u_t.
        //    For a rate 1/2 code, info bit u_t affects coded bits at step t
        //    (and subsequent steps via the register). As an approximation, we
        //    distribute the extrinsic info equally to both coded bits at step t.
        let extrinsic_coded: Vec<(f64, f64)> = extrinsic_info_bits.iter()
            .map(|&ext| {
                // Scale down to avoid overconfidence in early iterations
                let scaled = ext * 0.5;
                (scaled, scaled)
            })
            .collect();

        // 5. Re-interleave extrinsic coded LLRs back to Walsh block order
        let reinterleaved = permute_dibit_llrs(&extrinsic_coded, &int_perm);
        walsh_priors = Some(reinterleaved);

        // 6. Re-run Walsh correlation with priors
        let (new_intrinsic, new_score) = walsh_soft_with_priors(
            walsh_signs, equalized_iq, &phase_cos, &phase_sin,
            walsh_priors.as_deref(), n_blocks,
        );
        intrinsic_llrs = new_intrinsic;
        total_score = new_score;
        iteration_scores.push(total_score);
    }

    // Final BCJR pass to get hard bits
    let deinterleaved = permute_dibit_llrs(&intrinsic_llrs, &deint_perm);
    let channel_llrs: Vec<(f64, f64)> = deinterleaved.iter().copied().collect();
    let (_extrinsic, hard_bits) = bcjr.decode(&channel_llrs, &extrinsic_info_bits);

    (hard_bits, intrinsic_llrs, extrinsic_info_bits, iteration_scores)
}

// ============================================================================
// Walsh soft correlation with optional priors
// ============================================================================

/// Compute soft LLRs from Walsh correlation, optionally incorporating
/// extrinsic priors from the BCJR decoder.
///
/// The priors bias the correlation metrics for each quadbit candidate
/// before LLR computation. This is the key feedback path in the turbo loop:
/// the BCJR tells us which coded bits are likely, and we use that to
/// re-weight ambiguous Walsh blocks.
///
/// Returns (soft_dibit_llrs [192 pairs], total_augmented_score).
fn walsh_soft_with_priors(
    walsh_signs: &[[f64; 64]; 16],
    iq: &[(f64, f64)],
    phase_cos: &[f64],
    phase_sin: &[f64],
    priors: Option<&[(f64, f64)]>,  // 192 dibit LLR priors (in Walsh/interleaved order)
    n_blocks: usize,
) -> (Vec<(f64, f64)>, f64) {
    let n_phases = phase_cos.len();
    let mut soft_dibits = Vec::with_capacity(n_blocks * 2);
    let mut total_score = 0.0f64;
    let mut rot_i = vec![0.0f64; 64];

    for blk in 0..n_blocks {
        let start = blk * 64;
        let end = start + 64;
        if end > iq.len() { break; }
        let blk_iq = &iq[start..end];

        // Phase search + correlation: find best correlation score per candidate
        let mut candidate_corr = [f64::NEG_INFINITY; 16];

        for ph in 0..n_phases {
            let cos_t = phase_cos[ph];
            let sin_t = phase_sin[ph];

            for k in 0..64 {
                rot_i[k] = blk_iq[k].0 * cos_t + blk_iq[k].1 * sin_t;
            }

            for qb in 0..16usize {
                let signs = &walsh_signs[qb];
                let mut score = 0.0f64;
                for k in 0..64 {
                    score += rot_i[k] * signs[k];
                }
                if score > candidate_corr[qb] {
                    candidate_corr[qb] = score;
                }
            }
        }

        // Compute prior-augmented metrics for each candidate.
        // The prior for each bit adjusts candidates that are consistent
        // with the BCJR's belief about that bit.
        let mut candidate_aug = [0.0f64; 16];
        for qb in 0..16u8 {
            let mut aug = candidate_corr[qb as usize];

            if let Some(prior_dibits) = priors {
                let dibit_idx = blk * 2;
                // Each quadbit has 4 coded bits mapping to 2 dibit positions
                for bp in 0..4usize {
                    let di = dibit_idx + bp / 2;
                    if di < prior_dibits.len() {
                        let prior_llr = if bp % 2 == 0 {
                            prior_dibits[di].0
                        } else {
                            prior_dibits[di].1
                        };
                        let bit_val = (qb >> (3 - bp as u8)) & 1;
                        // Positive prior_llr means bit=1 is likely from BCJR.
                        // If this candidate has bit=1, boost it; bit=0, penalize.
                        aug += if bit_val == 1 { prior_llr * 0.5 } else { -prior_llr * 0.5 };
                    }
                }
            }

            candidate_aug[qb as usize] = aug;
        }

        // Track score using the augmented metrics
        let best_aug = candidate_aug.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        total_score += best_aug;

        // Block quality from raw correlation (not prior-augmented, to avoid
        // feedback instability where priors inflate quality artificially)
        let best_corr = candidate_corr.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let quality = (best_corr / 64.0).powi(2).clamp(0.01, 1.0);

        // Compute LLRs for each of the 4 bits using augmented metrics
        let mut block_llrs = [0.0f64; 4];

        for bit_pos in 0..4usize {
            let mask = 1u8 << (3 - bit_pos);  // MSB first
            let mut max_1 = f64::NEG_INFINITY;
            let mut max_0 = f64::NEG_INFINITY;

            for qb in 0..16u8 {
                let metric = candidate_aug[qb as usize];

                if (qb & mask) != 0 {
                    if metric > max_1 { max_1 = metric; }
                } else {
                    if metric > max_0 { max_0 = metric; }
                }
            }

            // Compute LLR: difference of best metrics for bit=1 vs bit=0
            // Normalize by the correlation magnitude to keep LLR scale stable
            let denom = (max_1.abs() + max_0.abs()).max(0.01);
            let llr_raw = (max_1 - max_0) / denom;
            block_llrs[bit_pos] = (llr_raw * quality * 8.0).clamp(-8.0, 8.0);
        }

        // Pack 4 bits into 2 soft dibits
        soft_dibits.push((block_llrs[0], block_llrs[1]));
        soft_dibits.push((block_llrs[2], block_llrs[3]));
    }

    (soft_dibits, total_score)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_trellis_construction() {
        let trellis = Trellis::new();

        // State 0, input 0 → next_state 0
        let br = &trellis.branches[0][0];
        assert_eq!(br.next_state, 0);

        // State 0, input 1 → next_state 1
        let br = &trellis.branches[0][1];
        assert_eq!(br.next_state, 1);

        // Check all states have exactly 2 predecessors
        for s in 0..NUM_STATES {
            assert_eq!(trellis.reverse[s].len(), 2,
                "State {} should have 2 predecessors", s);
        }
    }

    #[test]
    fn test_log_add() {
        // log(exp(0) + exp(0)) = log(2) ≈ 0.693
        let result = log_add(0.0, 0.0);
        assert!((result - 2.0f64.ln()).abs() < 1e-10);

        // log(exp(10) + exp(0)) ≈ 10
        let result = log_add(10.0, 0.0);
        assert!((result - 10.0).abs() < 1e-4);

        // log(exp(-inf) + exp(0)) = 0
        let result = log_add(LOG_ZERO, 0.0);
        assert!((result - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_bcjr_trivial() {
        let bcjr = BcjrDecoder::new();

        // Feed very confident LLRs — should decode cleanly
        // All-zeros codeword: for state 0, input 0, both outputs are 0
        // So LLR should be strongly negative (meaning bit=0 likely)
        let n = 10;
        let channel_llrs: Vec<(f64, f64)> = vec![(-5.0, -5.0); n];
        let apriori: Vec<f64> = vec![0.0; n];

        let (extrinsic, hard_bits) = bcjr.decode(&channel_llrs, &apriori);

        // All-zeros input should produce all-zeros output
        assert_eq!(hard_bits.len(), n);
        for &bit in &hard_bits {
            assert_eq!(bit, 0, "Expected all-zero decode");
        }
        assert_eq!(extrinsic.len(), n);
    }

    #[test]
    fn test_interleaver_round_trip() {
        let int_perm = interleave_permutation();
        let deint_perm = deinterleave_permutation();

        // Create test data
        let data: Vec<(f64, f64)> = (0..INTERLEAVER_SIZE)
            .map(|i| (i as f64, -(i as f64)))
            .collect();

        // Interleave then deinterleave should give original
        let interleaved = permute_dibit_llrs(&data, &int_perm);
        let recovered = permute_dibit_llrs(&interleaved, &deint_perm);

        for i in 0..INTERLEAVER_SIZE {
            assert!((data[i].0 - recovered[i].0).abs() < 1e-10,
                "Mismatch at index {}: expected {}, got {}", i, data[i].0, recovered[i].0);
        }
    }
}
