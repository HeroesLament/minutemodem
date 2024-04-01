//! PHY Modem - Trait-based waveform engine for HF modems
//!
//! This crate provides a unified PHY layer for MIL-STD-188-110D and 188-141D
//! waveforms. All protocol logic (scrambling, Walsh, interleaving, FEC) lives
//! in Elixir. Rust only handles symbol ↔ sample conversion.

use rustler::{Env, Term};

pub mod traits;
pub mod constellations;
pub mod pulse_shapes;
pub mod carriers;
pub mod timing;
pub mod modem;
pub mod nif;
mod utils;

// Re-export core types for convenience
pub use traits::{Constellation, PulseShape, Carrier, SymbolTiming};
pub use constellations::{Bpsk, Qpsk, Psk8, Qam16, Qam32, Qam64};
pub use pulse_shapes::RootRaisedCosine;
pub use carriers::Nco;
pub use timing::FixedTiming;
pub use modem::{Modulator, Demodulator, UnifiedModulator, UnifiedDemodulator, ConstellationType, DFEConfig};

fn on_load(env: Env, _info: Term) -> bool {
    let _ = rustler::resource!(nif::ModulatorResource, env);
    let _ = rustler::resource!(nif::DemodulatorResource, env);
    let _ = rustler::resource!(nif::UnifiedModulatorResource, env);
    let _ = rustler::resource!(nif::UnifiedDemodulatorResource, env);
    true
}

rustler::init!(
    "Elixir.MinuteModemCore.DSP.PhyModem",
    [
        // Legacy API
        nif::new,
        nif::modulate,
        nif::flush,
        nif::reset,
        
        // Generic modulator
        nif::mod_new,
        nif::mod_modulate,
        nif::mod_flush,
        nif::mod_reset,
        
        // Generic demodulator
        nif::demod_new,
        nif::demod_demodulate,
        nif::demod_reset,
        
        // Unified modulator
        nif::unified_mod_new,
        nif::unified_mod_modulate,
        nif::unified_mod_modulate_mixed,
        nif::unified_mod_set_constellation,
        nif::unified_mod_get_constellation,
        nif::unified_mod_flush,
        nif::unified_mod_reset,
        
        // Unified demodulator
        nif::unified_demod_new,
        nif::unified_demod_iq,
        nif::unified_demod_symbols,
        nif::unified_demod_set_constellation,
        nif::unified_demod_reset,
        
        // Equalizer functions
        nif::unified_demod_new_with_eq,
        nif::unified_demod_new_hf,
        nif::unified_demod_set_training,
        nif::unified_demod_reset_eq,
        nif::unified_demod_mse,
        nif::unified_demod_has_eq,
        nif::unified_demod_enable_eq,
        nif::unified_demod_disable_eq,
        nif::unified_demod_eq_mode,
    ],
    load = on_load
);