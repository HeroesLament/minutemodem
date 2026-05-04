defmodule MinuteModemCore.DSP.PhyModem do
  @moduledoc """
  Software-defined HF modem for MIL-STD-188-110D.
  """

  use Rustler,
    otp_app: :minutemodem_core,
    crate: :phy_modem

  # ============================================================================
  # Legacy API (backwards compatibility)
  # ============================================================================

  def new(_sample_rate), do: :erlang.nif_error(:nif_not_loaded)
  def modulate(_modulator, _symbols), do: :erlang.nif_error(:nif_not_loaded)
  def flush(_modulator), do: :erlang.nif_error(:nif_not_loaded)
  def reset(_modulator), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Generic Modulator
  # ============================================================================

  def mod_new(_modulation, _sample_rate, _symbol_rate \\ nil, _carrier_freq \\ nil),
    do: :erlang.nif_error(:nif_not_loaded)

  def mod_modulate(_modulator, _symbols), do: :erlang.nif_error(:nif_not_loaded)
  def mod_flush(_modulator), do: :erlang.nif_error(:nif_not_loaded)
  def mod_reset(_modulator), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Generic Demodulator
  # ============================================================================

  def demod_new(_modulation, _sample_rate, _symbol_rate \\ nil, _carrier_freq \\ nil),
    do: :erlang.nif_error(:nif_not_loaded)

  def demod_demodulate(_demodulator, _samples), do: :erlang.nif_error(:nif_not_loaded)
  def demod_reset(_demodulator), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Unified Modulator (runtime constellation switching)
  # ============================================================================

  def unified_mod_new(_constellation, _sample_rate),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_modulate(_modulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_modulate_mixed(_modulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_set_constellation(_modulator, _constellation),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_get_constellation(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_flush(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_reset(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Unified Demodulator
  # ============================================================================

  def unified_demod_new(_constellation, _sample_rate),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_iq(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_symbols(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_eq_iq(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_constellation(_demodulator, _constellation),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_reset(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Equalizer Functions
  # ============================================================================

  def unified_demod_new_with_eq(_constellation, _sample_rate, _ff_taps, _fb_taps, _mu),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_new_hf(_constellation, _sample_rate),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_training(_demodulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_reset_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_mse(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_has_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_enable_eq(_demodulator, _ff_taps, _fb_taps, _mu),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_disable_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_eq_mode(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # PLL Telemetry
  def unified_demod_enable_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_take_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_lock_detect(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_block_size(_demodulator, _size),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_get_block_size(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_enable_dfe_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_take_dfe_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Convenience wrapper
  # ============================================================================

  def unified_demod_with_eq(constellation, sample_rate, opts \\ []) do
    ff_taps = Keyword.get(opts, :ff_taps, 15)
    fb_taps = Keyword.get(opts, :fb_taps, 7)
    mu = Keyword.get(opts, :mu, 0.03)

    unified_demod_new_with_eq(constellation, sample_rate, ff_taps, fb_taps, mu)
  end

  # ============================================================================
  # Walsh Correlator
  # ============================================================================

  def walsh_correlator_new(_n_phases, _n_passes),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode_soft(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode_diagnostic(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_enable_telemetry(_correlator),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_take_telemetry(_correlator),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_turbo_decode(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets, _n_iterations),
    do: :erlang.nif_error(:nif_not_loaded)
end
