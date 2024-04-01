defmodule MinutemodemSimnet.Physics.Types do
  @moduledoc """
  Type definitions for the Rust physics NIF boundary.

  These structs map to Rust types and are used for
  NIF parameter passing.
  """

  defmodule ChannelParams do
    @moduledoc """
    Parameters for creating a WattersonChannel in Rust.

    Maps to MIL-STD-188-110D Appendix E channel specification.
    """

    @type t :: %__MODULE__{
            sample_rate: pos_integer(),
            delay_spread_samples: non_neg_integer(),
            doppler_bandwidth_hz: float(),
            snr_db: float(),
            carrier_freq_hz: float()
          }

    defstruct [
      :sample_rate,
      :delay_spread_samples,
      :doppler_bandwidth_hz,
      :snr_db,
      :carrier_freq_hz
    ]

    @doc """
    Creates channel params from resolved parameters.
    """
    def from_resolved(params) do
      delay_spread_samples =
        round(params.delay_spread_ms * params.sample_rate / 1000)

      %__MODULE__{
        sample_rate: params.sample_rate,
        delay_spread_samples: delay_spread_samples,
        doppler_bandwidth_hz: params.doppler_bandwidth_hz,
        snr_db: params.snr_db,
        carrier_freq_hz: params.carrier_freq_hz || 1800.0
      }
    end

    @doc """
    Converts to a map suitable for NIF encoding.
    """
    def to_nif_map(%__MODULE__{} = params) do
      %{
        sample_rate: params.sample_rate,
        delay_spread_samples: params.delay_spread_samples,
        doppler_bandwidth_hz: params.doppler_bandwidth_hz,
        snr_db: params.snr_db,
        carrier_freq_hz: params.carrier_freq_hz
      }
    end
  end

  defmodule ChannelState do
    @moduledoc """
    State snapshot from a Rust channel.

    Used for debugging and telemetry.

    Fields match the Rust ChannelState struct:
    - sample_index: Number of samples processed
    - tap0_phase: Current phase of tap 0 fading oscillator
    - tap1_phase: Current phase of tap 1 fading oscillator
    """

    @type t :: %__MODULE__{
            sample_index: non_neg_integer(),
            tap0_phase: float(),
            tap1_phase: float()
          }

    defstruct [
      :sample_index,
      :tap0_phase,
      :tap1_phase
    ]
  end
end
