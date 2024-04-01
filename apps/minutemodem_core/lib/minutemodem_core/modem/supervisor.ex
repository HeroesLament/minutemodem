defmodule MinuteModemCore.Modem.Supervisor do
  @moduledoc """
  Supervisor for a single modem instance.

  Owns the modem FSMs and event infrastructure:
  - TxFSM - Transmitter state machine
  - RxFSM - Receiver state machine
  - Arbiter - Half-duplex arbitration
  - Events - Pub/sub for interface adapters

  Restart strategy is :one_for_all because modem state is tightly coupled.
  If TX dies, RX state assumptions may be invalid (especially in half-duplex).
  """

  use Supervisor

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    Supervisor.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :supervisor}}}
  end

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    # Waveform parameters
    waveform = Keyword.get(opts, :waveform, 1)
    bw_khz = Keyword.get(opts, :bw_khz, 3)
    interleaver = Keyword.get(opts, :interleaver, :short)
    constraint_length = Keyword.get(opts, :constraint_length, 7)
    sample_rate = Keyword.get(opts, :sample_rate, 48000)
    duplex_mode = Keyword.get(opts, :duplex_mode, :full_duplex)
    rig_type = Keyword.get(opts, :rig_type, "physical")

    children = [
      # Event bus first - others depend on it
      {MinuteModemCore.Modem.Events, rig_id: rig_id},

      # Arbiter - manages half-duplex coordination
      {MinuteModemCore.Modem.Arbiter,
       rig_id: rig_id,
       mode: duplex_mode},

      # TX FSM
      {MinuteModemCore.Modem.TxFSM,
       rig_id: rig_id,
       waveform: waveform,
       bw_khz: bw_khz,
       interleaver: interleaver,
       constraint_length: constraint_length,
       sample_rate: sample_rate,
       rig_type: rig_type},

      # RX FSM
      {MinuteModemCore.Modem.RxFSM,
       rig_id: rig_id,
       bw_khz: bw_khz,
       sample_rate: 9600}  # RX uses 9600 for demod
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
