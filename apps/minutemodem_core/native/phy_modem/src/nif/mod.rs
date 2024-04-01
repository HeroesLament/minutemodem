//! NIF interface for Elixir
//!
//! Provides Rustler NIFs that expose the modulator and demodulator.
//! Modulation type is selected at construction time via atom matching.

use rustler::{Atom, NifResult, ResourceArc};
use std::sync::Mutex;

use crate::carriers::Nco;
use crate::constellations::*;
use crate::modem::{Demodulator, Modulator, UnifiedModulator, UnifiedDemodulator, ConstellationType, DFEConfig};
use crate::pulse_shapes::RootRaisedCosine;
use crate::timing::FixedTiming;
use crate::traits::{Carrier, Constellation, PulseShape, SymbolTiming};

// Atoms for modulation types
rustler::atoms! {
    ok,
    error,
    none,
    // Modulation types
    bpsk,
    qpsk,
    psk8,
    qam16,
    qam32,
    qam64,
    // Equalizer modes
    cma,
    dd,
}

fn atom_to_constellation(atom: Atom) -> Result<ConstellationType, &'static str> {
    if atom == bpsk() {
        Ok(ConstellationType::Bpsk)
    } else if atom == qpsk() {
        Ok(ConstellationType::Qpsk)
    } else if atom == psk8() {
        Ok(ConstellationType::Psk8)
    } else if atom == qam16() {
        Ok(ConstellationType::Qam16)
    } else if atom == qam32() {
        Ok(ConstellationType::Qam32)
    } else if atom == qam64() {
        Ok(ConstellationType::Qam64)
    } else {
        Err("unsupported modulation type")
    }
}

fn constellation_to_atom(ct: ConstellationType) -> Atom {
    match ct {
        ConstellationType::Bpsk => bpsk(),
        ConstellationType::Qpsk => qpsk(),
        ConstellationType::Psk8 => psk8(),
        ConstellationType::Qam16 => qam16(),
        ConstellationType::Qam32 => qam32(),
        ConstellationType::Qam64 => qam64(),
    }
}

// ============================================================================
// Type-erased wrappers for NIF resources
// ============================================================================

/// Trait object wrapper for modulators
pub trait ModulatorTrait: Send + Sync {
    fn modulate(&mut self, symbols: &[u8]) -> Vec<i16>;
    fn flush(&mut self) -> Vec<i16>;
    fn reset(&mut self);
}

/// Trait object wrapper for demodulators
pub trait DemodulatorTrait: Send + Sync {
    fn demodulate(&mut self, samples: &[i16]) -> Vec<u8>;
    fn reset(&mut self);
}

// Implement trait for concrete modulator types
impl<C, P, K, T> ModulatorTrait for Modulator<C, P, K, T>
where
    C: Constellation + Send + Sync,
    P: PulseShape + Send + Sync,
    K: Carrier + Send + Sync,
    T: SymbolTiming + Send + Sync,
{
    fn modulate(&mut self, symbols: &[u8]) -> Vec<i16> {
        Modulator::modulate(self, symbols)
    }

    fn flush(&mut self) -> Vec<i16> {
        Modulator::flush(self)
    }

    fn reset(&mut self) {
        Modulator::reset(self)
    }
}

// Implement trait for concrete demodulator types
impl<C, P, K, T> DemodulatorTrait for Demodulator<C, P, K, T>
where
    C: Constellation + Send + Sync,
    P: PulseShape + Send + Sync,
    K: Carrier + Send + Sync,
    T: SymbolTiming + Send + Sync,
{
    fn demodulate(&mut self, samples: &[i16]) -> Vec<u8> {
        Demodulator::demodulate(self, samples)
    }

    fn reset(&mut self) {
        Demodulator::reset(self)
    }
}

/// NIF resource wrapper for modulator
pub struct ModulatorResource {
    pub inner: Mutex<Box<dyn ModulatorTrait>>,
}

/// NIF resource wrapper for demodulator
pub struct DemodulatorResource {
    pub inner: Mutex<Box<dyn DemodulatorTrait>>,
}

// ============================================================================
// Factory functions - match once, construct specialized type
// ============================================================================

/// Build a modulator for the given modulation type
fn build_modulator(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: u32,
    carrier_freq: f64,
) -> Result<Box<dyn ModulatorTrait>, &'static str> {
    let timing = FixedTiming::new(sample_rate, symbol_rate);
    let sps = timing.samples_per_symbol();
    let pulse = RootRaisedCosine::default_for_sps(sps);
    let carrier = Nco::new(carrier_freq, sample_rate);

    if modulation == bpsk() {
        Ok(Box::new(Modulator::new(Bpsk, pulse, carrier, timing)))
    } else if modulation == qpsk() {
        Ok(Box::new(Modulator::new(Qpsk, pulse, carrier, timing)))
    } else if modulation == psk8() {
        Ok(Box::new(Modulator::new(Psk8, pulse, carrier, timing)))
    } else if modulation == qam16() {
        Ok(Box::new(Modulator::new(Qam16, pulse, carrier, timing)))
    } else if modulation == qam32() {
        Ok(Box::new(Modulator::new(Qam32, pulse, carrier, timing)))
    } else if modulation == qam64() {
        Ok(Box::new(Modulator::new(Qam64, pulse, carrier, timing)))
    } else {
        Err("unsupported modulation type")
    }
}

/// Build a demodulator for the given modulation type
fn build_demodulator(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: u32,
    carrier_freq: f64,
) -> Result<Box<dyn DemodulatorTrait>, &'static str> {
    let timing = FixedTiming::new(sample_rate, symbol_rate);
    let sps = timing.samples_per_symbol();
    let pulse = RootRaisedCosine::default_for_sps(sps);
    let carrier = Nco::new(carrier_freq, sample_rate);

    if modulation == bpsk() {
        Ok(Box::new(Demodulator::new(Bpsk, pulse, carrier, timing)))
    } else if modulation == qpsk() {
        Ok(Box::new(Demodulator::new(Qpsk, pulse, carrier, timing)))
    } else if modulation == psk8() {
        Ok(Box::new(Demodulator::new(Psk8, pulse, carrier, timing)))
    } else if modulation == qam16() {
        Ok(Box::new(Demodulator::new(Qam16, pulse, carrier, timing)))
    } else if modulation == qam32() {
        Ok(Box::new(Demodulator::new(Qam32, pulse, carrier, timing)))
    } else if modulation == qam64() {
        Ok(Box::new(Demodulator::new(Qam64, pulse, carrier, timing)))
    } else {
        Err("unsupported modulation type")
    }
}

// ============================================================================
// Modulator NIFs
// ============================================================================

/// Create a new modulator
///
/// # Arguments
/// * `modulation` - Atom: :bpsk, :qpsk, :psk8, :qam16, :qam32, :qam64
/// * `sample_rate` - Sample rate in Hz (must be integer multiple of symbol_rate)
/// * `symbol_rate` - Symbol rate in baud (default 2400)
/// * `carrier_freq` - Carrier frequency in Hz (default 1800)
#[rustler::nif]
pub fn mod_new(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<ModulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);

    let modulator = build_modulator(modulation, sample_rate, symbol_rate, carrier_freq)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(ResourceArc::new(ModulatorResource {
        inner: Mutex::new(modulator),
    }))
}

/// Modulate symbols to audio samples
#[rustler::nif]
pub fn mod_modulate(
    modulator: ResourceArc<ModulatorResource>,
    symbols: Vec<u8>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(state.modulate(&symbols))
}

/// Flush modulator filter tail
#[rustler::nif]
pub fn mod_flush(modulator: ResourceArc<ModulatorResource>) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(state.flush())
}

/// Reset modulator state
#[rustler::nif]
pub fn mod_reset(modulator: ResourceArc<ModulatorResource>) -> Atom {
    if let Ok(mut state) = modulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// Demodulator NIFs
// ============================================================================

/// Create a new demodulator
#[rustler::nif]
pub fn demod_new(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<DemodulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);

    let demodulator = build_demodulator(modulation, sample_rate, symbol_rate, carrier_freq)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(ResourceArc::new(DemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Demodulate audio samples to symbols
#[rustler::nif]
pub fn demod_demodulate(
    demodulator: ResourceArc<DemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<u8>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(state.demodulate(&samples))
}

/// Reset demodulator state
#[rustler::nif]
pub fn demod_reset(demodulator: ResourceArc<DemodulatorResource>) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// Legacy API (backwards compatibility with existing 8-PSK code)
// ============================================================================

/// Legacy: Create 8-PSK modulator (for backwards compatibility)
#[rustler::nif]
pub fn new(sample_rate: u32) -> NifResult<ResourceArc<ModulatorResource>> {
    let modulator = build_modulator(psk8(), sample_rate, 2400, 1800.0)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(ResourceArc::new(ModulatorResource {
        inner: Mutex::new(modulator),
    }))
}

/// Legacy: Modulate (for backwards compatibility)
#[rustler::nif]
pub fn modulate(
    modulator: ResourceArc<ModulatorResource>,
    symbols: Vec<u8>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(state.modulate(&symbols))
}

/// Legacy: Flush (for backwards compatibility)
#[rustler::nif]
pub fn flush(modulator: ResourceArc<ModulatorResource>) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(state.flush())
}

/// Legacy: Reset (for backwards compatibility)
#[rustler::nif]
pub fn reset(modulator: ResourceArc<ModulatorResource>) -> Atom {
    if let Ok(mut state) = modulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// Unified Modulator/Demodulator (runtime constellation switching)
// ============================================================================

/// Resource wrapper for unified modulator
pub struct UnifiedModulatorResource {
    pub inner: Mutex<UnifiedModulator>,
}

/// Resource wrapper for unified demodulator  
pub struct UnifiedDemodulatorResource {
    pub inner: Mutex<UnifiedDemodulator>,
}

/// Create a unified modulator with runtime constellation switching
#[rustler::nif]
pub fn unified_mod_new(
    modulation: Atom,
    sample_rate: u32,
) -> NifResult<ResourceArc<UnifiedModulatorResource>> {
    let symbol_rate = 2400;
    let carrier_freq = 1800.0;
    
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let modulator = UnifiedModulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
    
    Ok(ResourceArc::new(UnifiedModulatorResource {
        inner: Mutex::new(modulator),
    }))
}

/// Modulate symbols using current constellation
#[rustler::nif]
pub fn unified_mod_modulate(
    modulator: ResourceArc<UnifiedModulatorResource>,
    symbols: Vec<u8>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    Ok(state.modulate(&symbols))
}

/// Modulate with per-symbol constellation
/// Takes list of {symbol, constellation_atom} tuples
#[rustler::nif]
pub fn unified_mod_modulate_mixed(
    modulator: ResourceArc<UnifiedModulatorResource>,
    symbols: Vec<(u8, Atom)>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    // Convert atoms to ConstellationType
    let mixed: Result<Vec<_>, _> = symbols
        .into_iter()
        .map(|(sym, atom)| {
            atom_to_constellation(atom).map(|ct| (sym, ct))
        })
        .collect();
    
    let mixed = mixed.map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    Ok(state.modulate_mixed(&mixed))
}

/// Switch constellation without resetting filter state
#[rustler::nif]
pub fn unified_mod_set_constellation(
    modulator: ResourceArc<UnifiedModulatorResource>,
    modulation: Atom,
) -> NifResult<Atom> {
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    state.set_constellation(constellation);
    Ok(ok())
}

/// Get current constellation
#[rustler::nif]
pub fn unified_mod_get_constellation(
    modulator: ResourceArc<UnifiedModulatorResource>,
) -> NifResult<Atom> {
    let state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    Ok(constellation_to_atom(state.constellation()))
}

/// Flush modulator filter tail
#[rustler::nif]
pub fn unified_mod_flush(
    modulator: ResourceArc<UnifiedModulatorResource>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    Ok(state.flush())
}

/// Reset modulator state
#[rustler::nif]
pub fn unified_mod_reset(modulator: ResourceArc<UnifiedModulatorResource>) -> Atom {
    if let Ok(mut state) = modulator.inner.lock() {
        state.reset();
    }
    ok()
}

/// Create a unified demodulator
#[rustler::nif]
pub fn unified_demod_new(
    modulation: Atom,
    sample_rate: u32,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = 2400;
    let carrier_freq = 1800.0;
    
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let demodulator = UnifiedDemodulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
    
    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Demodulate to I/Q pairs
#[rustler::nif]
pub fn unified_demod_iq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<(f64, f64)>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    Ok(state.demodulate_iq(&samples))
}

/// Demodulate to symbols
#[rustler::nif]
pub fn unified_demod_symbols(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<u8>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    Ok(state.demodulate(&samples))
}

/// Switch demodulator constellation
#[rustler::nif]
pub fn unified_demod_set_constellation(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    modulation: Atom,
) -> NifResult<Atom> {
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    state.set_constellation(constellation);
    Ok(ok())
}

/// Reset demodulator state
#[rustler::nif]
pub fn unified_demod_reset(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// Equalizer NIFs
// ============================================================================

/// Create a unified demodulator with DFE equalizer enabled
#[rustler::nif]
pub fn unified_demod_new_with_eq(
    modulation: Atom,
    sample_rate: u32,
    ff_taps: usize,
    fb_taps: usize,
    mu: f64,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = 2400;
    let carrier_freq = 1800.0;
    
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let config = DFEConfig {
        ff_taps,
        fb_taps,
        mu,
        mu_cma: mu / 6.0,
        leakage: 0.9999,
        update_threshold: 0.1,
        cma_to_dd_threshold: 0.3,
        cma_min_symbols: 50,
    };
    
    let demodulator = UnifiedDemodulator::with_equalizer(
        constellation, sample_rate, symbol_rate, carrier_freq, config
    );
    
    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Create demodulator with default HF skywave equalizer settings
#[rustler::nif]
pub fn unified_demod_new_hf(
    modulation: Atom,
    sample_rate: u32,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = 2400;
    let carrier_freq = 1800.0;
    
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    
    let demodulator = UnifiedDemodulator::with_hf_equalizer(
        constellation, sample_rate, symbol_rate, carrier_freq
    );
    
    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Set training symbols for equalizer acquisition
#[rustler::nif]
pub fn unified_demod_set_training(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    symbols: Vec<u8>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.set_training_symbols(symbols);
    }
    ok()
}

/// Reset equalizer state
#[rustler::nif]
pub fn unified_demod_reset_eq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.reset_equalizer();
    }
    ok()
}

/// Get current mean squared error
#[rustler::nif]
pub fn unified_demod_mse(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> f64 {
    demodulator
        .inner
        .lock()
        .map(|state| state.equalizer_mse().unwrap_or(0.0))
        .unwrap_or(0.0)
}

/// Check if equalizer is enabled
#[rustler::nif]
pub fn unified_demod_has_eq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> bool {
    demodulator
        .inner
        .lock()
        .map(|state| state.has_equalizer())
        .unwrap_or(false)
}

/// Enable equalizer on existing demodulator
#[rustler::nif]
pub fn unified_demod_enable_eq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    ff_taps: usize,
    fb_taps: usize,
    mu: f64,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        let config = DFEConfig {
            ff_taps,
            fb_taps,
            mu,
            mu_cma: mu / 6.0,  // CMA uses smaller step size
            leakage: 0.9999,
            update_threshold: 0.1,
            cma_to_dd_threshold: 0.3,
            cma_min_symbols: 50,
        };
        state.enable_equalizer(config);
    }
    ok()
}

/// Disable equalizer
#[rustler::nif]
pub fn unified_demod_disable_eq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.disable_equalizer();
    }
    ok()
}

/// Get equalizer mode (:cma or :dd)
#[rustler::nif]
pub fn unified_demod_eq_mode(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Atom {
    demodulator
        .inner
        .lock()
        .map(|state| {
            if let Some(mode) = state.equalizer_mode() {
                match mode {
                    crate::modem::EqMode::CMA => cma(),
                    crate::modem::EqMode::DD => dd(),
                }
            } else {
                none()
            }
        })
        .unwrap_or(none())
}