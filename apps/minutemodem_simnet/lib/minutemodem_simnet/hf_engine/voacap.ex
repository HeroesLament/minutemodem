defmodule MinutemodemSimnet.HFEngine.VOACAP do
  @moduledoc """
  VOACAP-style HF propagation engine.

  Uses an analytical ionospheric model driven by solar activity (SSN/SFI)
  to compute realistic HF channel parameters. Key features:

  - foF2/MUF calculation from simplified ionospheric model
  - SSN-driven propagation — MUF, absorption, noise all vary with solar cycle
  - D-layer absorption model (frequency-dependent, solar zenith angle)
  - Atmospheric + galactic noise model (ITU-R P.372 simplified)
  - Multi-hop geometry for long paths
  - Realistic skip zone boundaries that vary with solar conditions

  ## Solar Conditions

  Pass via epoch metadata or opts:

      %{ssn: 100, sfi: 150, k_index: 2}

  - `ssn` — Sunspot number (0-200). Drives MUF: higher SSN = higher MUF = more HF bands open.
  - `sfi` — Solar flux index (65-300). Correlates with SSN, used for absorption.
  - `k_index` — Geomagnetic disturbance (0-9). Higher = more fading, absorption.
  """

  @behaviour MinutemodemSimnet.HFEngine

  @impl true
  def name, do: "VOACAP (analytical ionospheric)"

  @impl true
  def compute_channel_params(from_station, to_station, freq_hz, opts \\ []) do
    # TODO: Implement VOACAP-style ionospheric model
    # For now, delegate to Naive as a placeholder
    MinutemodemSimnet.HFEngine.Naive.compute_channel_params(
      from_station, to_station, freq_hz, opts
    )
  end
end
