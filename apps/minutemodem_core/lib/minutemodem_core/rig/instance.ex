defmodule MinuteModemCore.Rig.Instance do
  @moduledoc """
  Per-rig supervisor.

  Manages the process tree for a single rig instance:
  - Control (PTT, frequency, mode - talks to rigctld/FLRig/simulator)
  - Audio (RX/TX routing and subscriber management)
  - AudioPipeline (routes modem TX to soundcard)
  - SimnetBridge (for test rigs: connects to channel simulation)
  - Modem (DTE-level TX/RX state machines wrapping Modem110D)
  - ALE (link establishment)
  - Interface (optional MIL-STD-188-110D Appendix A or KISS)

  Restart strategy is :one_for_all because if control dies,
  audio state is likely invalid and vice versa.
  """

  use Supervisor
  alias MinuteModemCore.Rig.Types

  def start_link(spec) do
    Supervisor.start_link(__MODULE__, spec, name: via(spec.id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, rig_id}}
  end

  @impl true
  def init(spec) do
    rig_type = Map.get(spec, :rig_type, "test")

    audio_opts = [
      rig_id: spec.id,
      rig_type: rig_type,
      sample_rate: get_sample_rate(spec),
      operator_host: Map.get(spec, :operator_host),
      operator_rx_port: Map.get(spec, :operator_rx_port, 5001),
      operator_tx_port: Map.get(spec, :operator_tx_port, 5000),
      decoder_pid: nil,
      encoder_pid: nil
    ]

    ale_rx_opts = [rig_id: spec.id, sample_rate: 9600]

    ale_tx_opts = [
      rig_id: spec.id,
      sample_rate: get_ale_sample_rate(spec)
    ]

    ale_link_opts = [
      rig_id: spec.id,
      self_addr: Map.get(spec, :self_addr, 0x0000)
    ]

    modem_opts = [
      rig_id: spec.id,
      waveform: Map.get(spec, :waveform, 1),
      bw_khz: Map.get(spec, :bw_khz, 3),
      interleaver: Map.get(spec, :interleaver, :short),
      constraint_length: Map.get(spec, :constraint_length, 7),
      sample_rate: Map.get(spec, :modem_sample_rate, 9600),
      duplex_mode: Map.get(spec, :duplex_mode, :full_duplex),
      rig_type: rig_type
    ]

    interface_type = Map.get(spec, :interface_type, :none)
    control_config = Map.get(spec, :control_config, %{})
    dte_port = Map.get(control_config, "dte_port") || Map.get(control_config, :dte_port) || 3000

    interface_opts = [
      rig_id: spec.id,
      port: dte_port
    ]

    children =
      [
        {MinuteModemCore.Rig.Control, spec},
        {MinuteModemCore.Rig.Audio, spec},
        {MinuteModemCore.Modem.Supervisor, modem_opts},
        {MinuteModemCore.Rig.AudioPipeline, audio_opts},
        {MinuteModemCore.Rig.AudioEndpoint, rig_id: spec.id},
        {MinuteModemCore.Voice, rig_id: spec.id},
        simnet_bridge_child(rig_type, spec),
        {MinuteModemCore.ALE.Receiver, ale_rx_opts},
        {MinuteModemCore.ALE.Transmitter, ale_tx_opts},
        {MinuteModemCore.ALE.Link, ale_link_opts},
        interface_child(interface_type, interface_opts)
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_all)
  end

  # --- SimnetBridge for test/simulator rigs ---
  # Always start for test rigs - bridge handles connection internally

  defp simnet_bridge_child(rig_type, spec) when rig_type in ["test", "simulator"] do
    {MinuteModemCore.Rig.SimnetBridge, spec}
  end

  defp simnet_bridge_child(_rig_type, _spec), do: nil

  # --- Interface selection ---

  defp interface_child(:mil110d, opts) do
    {MinuteModemCore.Interface.MIL110D.Supervisor, opts}
  end

  defp interface_child(:kiss, opts) do
    {MinuteModemCore.Interface.KISS, opts}
  end

  defp interface_child(:none, _opts), do: nil
  defp interface_child(nil, _opts), do: nil

  # --- Convenience accessors ---

  def control_pid(rig_id) do
    find_child(rig_id, MinuteModemCore.Rig.Control)
  end

  def audio_pid(rig_id) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def audio_pipeline_pid(rig_id) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio_pipeline}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def simnet_bridge_pid(rig_id) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, {rig_id, :simnet_bridge}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def audio_endpoint_pid(rig_id) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, {rig_id, :audio_endpoint}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def voice_pid(rig_id) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, {rig_id, :voice}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp find_child(rig_id, module) do
    case Registry.lookup(MinuteModemCore.Rig.InstanceRegistry, rig_id) do
      [{sup_pid, _}] ->
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {^module, pid, :worker, _} -> pid
          _ -> nil
        end)

      [] ->
        nil
    end
  end

  defp get_sample_rate(spec) do
    rig_type = Map.get(spec, :rig_type, "test")

    case Types.module_for(rig_type) do
      nil -> 9600
      module -> module.audio_config().sample_rate
    end
  end

  defp get_ale_sample_rate(_spec), do: 9600
end
