defmodule MinuteModemCore.ALE.Link do
  @moduledoc """
  MIL-STD-188-141D 4G ALE Link State Machine.

  Manages the lifecycle of an ALE link from idle through
  call setup, linked state, and termination.

  ## States

  - `:idle` - Not in a link, ready to call or scan
  - `:scanning` - Listening for incoming calls (capture probes)
  - `:lbt` - Listen Before Transmit (checking channel clear)
  - `:calling` - Sent LSU_Req, waiting for LSU_Conf
  - `:lbr` - Listen Before Respond (received LSU_Req, checking channel)
  - `:responding` - Sending LSU_Conf
  - `:linked` - Link established, ready for traffic
  - `:terminating` - Sending LSU_Term

  ## Waveform Options

  - `:deep` - Deep WALE (240ms preamble, ~150 bps, challenging channels)
  - `:fast` - Fast WALE (120ms preamble, ~2400 bps, good channels)
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias MinuteModemCore.ALE.{PDU, Waveform}

  # Default timing parameters (milliseconds)
  @default_timing %{
    t_lbt: 200,           # Listen before transmit duration
    t_lbr: 200,           # Listen before respond duration
    t_tune: 40,           # Radio tuning time
    t_handshake: 100,     # PDU processing + radio turnaround
    t_response: 2000,     # Wait for response to LSU_Req
    t_traffic: 3000,      # Wait for traffic after link setup
    t_activity: 30_000    # Link inactivity timeout
  }

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc """
  Start a link state machine for a rig.
  """
  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    self_addr = Keyword.fetch!(opts, :self_addr)

    GenStateMachine.start_link(
      __MODULE__,
      %{rig_id: rig_id, self_addr: self_addr, timing: @default_timing},
      name: via(rig_id)
    )
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Rig.InstanceRegistry, {rig_id, :ale_link}}}
  end

  @doc """
  Start scanning for incoming ALE calls.
  """
  def scan(rig_id, opts \\ []) do
    GenStateMachine.call(via(rig_id), {:scan, opts})
  end

  @doc """
  Stop scanning or cancel current operation, return to idle.
  """
  def stop(rig_id) do
    GenStateMachine.cast(via(rig_id), :stop)
  end

  @doc """
  Initiate a call to a destination address.
  """
  def call(rig_id, dest_addr, opts \\ []) do
    GenStateMachine.call(via(rig_id), {:call, dest_addr, opts})
  end

  @doc """
  Terminate the current link.
  """
  def terminate_link(rig_id, reason \\ :normal) do
    GenStateMachine.cast(via(rig_id), {:terminate, reason})
  end

  @doc """
  Get current link state.
  """
  def get_state(rig_id) do
    GenStateMachine.call(via(rig_id), :get_state)
  end

  @doc """
  Notify the state machine of a received PDU.
  Called by the decoder when a valid PDU is received.
  """
  def rx_pdu(rig_id, pdu) do
    GenStateMachine.cast(via(rig_id), {:rx_pdu, pdu})
  end

  @doc """
  Notify that LBT/LBR sensing is complete.
  """
  def channel_sense_complete(rig_id, result) when result in [:clear, :busy] do
    GenStateMachine.cast(via(rig_id), {:channel_sense, result})
  end

  # -------------------------------------------------------------------
  # GenStateMachine Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(data) do
    Logger.info("ALE Link starting for rig #{data.rig_id}, self_addr=0x#{Integer.to_string(data.self_addr, 16)}")

    initial_data = Map.merge(data, %{
      remote_addr: nil,
      call_opts: %{},
      link_info: nil,
      waveform: :fast  # Default waveform
    })

    {:ok, :idle, initial_data}
  end

  # -------------------------------------------------------------------
  # State: IDLE
  # -------------------------------------------------------------------

  def idle(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering IDLE")
    broadcast_state_change(data.rig_id, :idle, nil)
    {:keep_state, %{data | remote_addr: nil, link_info: nil}}
  end

  def idle({:call, from}, {:scan, opts}, data) do
    waveform = Keyword.get(opts, :waveform, :fast)
    Logger.info("ALE Link [#{data.rig_id}] starting SCAN with #{waveform} waveform")

    new_data = %{data | waveform: waveform}
    {:next_state, :scanning, new_data, [{:reply, from, :ok}]}
  end

  def idle({:call, from}, {:call, dest_addr, opts}, data) do
    waveform = Keyword.get(opts, :waveform, :deep)
    Logger.info("ALE Link [#{data.rig_id}] initiating call to 0x#{Integer.to_string(dest_addr, 16)} with #{waveform}")

    new_data = %{data |
      remote_addr: dest_addr,
      call_opts: Map.new(opts),
      waveform: waveform
    }

    # Start LBT
    {:next_state, :lbt, new_data,
     [{:reply, from, :ok}, {:state_timeout, data.timing.t_lbt, :lbt_complete}]}
  end

  def idle({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, {:idle, nil}}]}
  end

  def idle(:cast, {:rx_pdu, %PDU.LsuReq{} = pdu}, data) do
    # Received a call while idle - are we the called station?
    if pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received call from 0x#{Integer.to_string(pdu.caller_addr, 16)}")

      new_data = %{data |
        remote_addr: pdu.caller_addr,
        link_info: %{
          caller_addr: pdu.caller_addr,
          called_addr: pdu.called_addr,
          voice: pdu.voice,
          traffic_type: pdu.traffic_type,
          assigned_subchannels: pdu.assigned_subchannels,
          occupied_subchannels: pdu.occupied_subchannels,
          rx_snr: nil
        }
      }

      # Start LBR
      {:next_state, :lbr, new_data,
       [{:state_timeout, data.timing.t_lbr, :lbr_complete}]}
    else
      Logger.debug("ALE Link [#{data.rig_id}] ignoring call for 0x#{Integer.to_string(pdu.called_addr, 16)}")
      :keep_state_and_data
    end
  end

  def idle(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data
  def idle(:cast, {:terminate, _reason}, _data), do: :keep_state_and_data
  def idle(:cast, :stop, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: SCANNING
  # -------------------------------------------------------------------

  def scanning(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering SCANNING")
    broadcast_state_change(data.rig_id, :scanning, %{waveform: data.waveform})
    # TODO: Start the receiver listening for capture probes
    :keep_state_and_data
  end

  def scanning({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:scanning, %{waveform: data.waveform}}}]}
  end

  def scanning({:call, from}, {:call, _dest_addr, _opts}, _data) do
    # Can't call while scanning
    {:keep_state_and_data, [{:reply, from, {:error, :scanning}}]}
  end

  def scanning({:call, from}, {:scan, _opts}, _data) do
    # Already scanning
    {:keep_state_and_data, [{:reply, from, {:error, :already_scanning}}]}
  end

  def scanning(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] stopping scan")
    {:next_state, :idle, data}
  end

  def scanning(:cast, {:rx_pdu, %PDU.LsuReq{} = pdu}, data) do
    # Received a call while scanning
    if pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received call while scanning from 0x#{Integer.to_string(pdu.caller_addr, 16)}")

      new_data = %{data |
        remote_addr: pdu.caller_addr,
        link_info: %{
          caller_addr: pdu.caller_addr,
          called_addr: pdu.called_addr,
          voice: pdu.voice,
          traffic_type: pdu.traffic_type,
          assigned_subchannels: pdu.assigned_subchannels,
          occupied_subchannels: pdu.occupied_subchannels,
          rx_snr: nil
        }
      }

      {:next_state, :lbr, new_data,
       [{:state_timeout, data.timing.t_lbr, :lbr_complete}]}
    else
      :keep_state_and_data
    end
  end

  def scanning(:cast, {:rx_pdu, _pdu}, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # State: LBT (Listen Before Transmit)
  # -------------------------------------------------------------------

  def lbt(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering LBT")
    broadcast_state_change(data.rig_id, :lbt, data.remote_addr)
    :keep_state_and_data
  end

  def lbt(:state_timeout, :lbt_complete, data) do
    Logger.debug("ALE Link [#{data.rig_id}] LBT complete, channel clear")
    {:next_state, :calling, data}
  end

  def lbt(:cast, {:channel_sense, :busy}, data) do
    Logger.warning("ALE Link [#{data.rig_id}] channel busy during LBT")
    broadcast_event(data.rig_id, :call_failed, :channel_busy)
    {:next_state, :idle, data}
  end

  def lbt({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:lbt, data.remote_addr}}]}
  end

  def lbt(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled during LBT")
    {:next_state, :idle, data}
  end

  def lbt(:cast, {:terminate, _reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled during LBT")
    {:next_state, :idle, data}
  end

  # -------------------------------------------------------------------
  # State: CALLING
  # -------------------------------------------------------------------

  def calling(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering CALLING")
    broadcast_state_change(data.rig_id, :calling, data.remote_addr)

    # Build and transmit LSU_Req using selected waveform
    waveform = Map.get(data.call_opts, :waveform, data.waveform)
    tuner_time_ms = Map.get(data.call_opts, :tuner_time_ms, 0)

    pdu = %PDU.LsuReq{
      caller_addr: data.self_addr,
      called_addr: data.remote_addr,
      voice: Map.get(data.call_opts, :voice, false),
      traffic_type: Map.get(data.call_opts, :traffic_type, 0),
      assigned_subchannels: Map.get(data.call_opts, :assigned_subchannels, 0xFFFF),
      occupied_subchannels: Map.get(data.call_opts, :occupied_subchannels, 0)
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      async: true,
      tuner_time_ms: tuner_time_ms,
      capture_probe_count: 1,
      preamble_count: 1
    )

    # Send to modulator
    transmit_frame(data.rig_id, symbols)

    # Calculate TX duration and set response timeout
    timing = Waveform.frame_timing(pdu_binary, waveform: waveform, tuner_time_ms: tuner_time_ms)
    response_timeout = round(timing.duration_ms) + data.timing.t_response

    {:keep_state_and_data, [{:state_timeout, response_timeout, :response_timeout}]}
  end

  def calling(:state_timeout, :response_timeout, data) do
    Logger.warning("ALE Link [#{data.rig_id}] no response from 0x#{Integer.to_string(data.remote_addr, 16)}")

    send_terminate(data, PDU.LsuTerm.reason_timeout())

    broadcast_event(data.rig_id, :call_failed, :no_response)
    {:next_state, :idle, data}
  end

  def calling(:cast, {:rx_pdu, %PDU.LsuConf{} = pdu}, data) do
    if pdu.caller_addr == data.self_addr and pdu.called_addr == data.remote_addr do
      Logger.info("ALE Link [#{data.rig_id}] received confirm from 0x#{Integer.to_string(data.remote_addr, 16)}")

      link_info = %{
        caller_addr: data.self_addr,
        called_addr: data.remote_addr,
        voice: pdu.voice,
        snr: pdu.snr,
        tx_subchannels: pdu.tx_subchannels,
        rx_subchannels: pdu.rx_subchannels,
        we_are: :caller
      }

      new_data = %{data | link_info: link_info}
      {:next_state, :linked, new_data}
    else
      :keep_state_and_data
    end
  end

  def calling(:cast, {:rx_pdu, %PDU.LsuTerm{} = pdu}, data) do
    if pdu.called_addr == data.self_addr or pdu.caller_addr == data.remote_addr do
      Logger.info("ALE Link [#{data.rig_id}] call rejected, reason=#{pdu.reason}")
      broadcast_event(data.rig_id, :call_failed, {:rejected, pdu.reason})
      {:next_state, :idle, data}
    else
      :keep_state_and_data
    end
  end

  def calling({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:calling, data.remote_addr}}]}
  end

  def calling(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled by user")
    send_terminate(data, reason_to_code(:normal))
    {:next_state, :idle, data}
  end

  def calling(:cast, {:terminate, reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] call cancelled by user")
    send_terminate(data, reason_to_code(reason))
    {:next_state, :idle, data}
  end

  # -------------------------------------------------------------------
  # State: LBR (Listen Before Respond)
  # -------------------------------------------------------------------

  def lbr(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering LBR")
    broadcast_state_change(data.rig_id, :lbr, data.remote_addr)
    :keep_state_and_data
  end

  def lbr(:state_timeout, :lbr_complete, data) do
    Logger.debug("ALE Link [#{data.rig_id}] LBR complete, responding")
    {:next_state, :responding, data}
  end

  def lbr(:cast, {:channel_sense, :busy}, data) do
    Logger.warning("ALE Link [#{data.rig_id}] channel busy during LBR, not responding")
    broadcast_event(data.rig_id, :incoming_call_dropped, :channel_busy)
    {:next_state, :idle, data}
  end

  def lbr({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:lbr, data.remote_addr}}]}
  end

  def lbr(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] response cancelled")
    {:next_state, :idle, data}
  end

  # -------------------------------------------------------------------
  # State: RESPONDING
  # -------------------------------------------------------------------

  def responding(:enter, _old_state, data) do
    Logger.debug("ALE Link [#{data.rig_id}] entering RESPONDING")
    broadcast_state_change(data.rig_id, :responding, data.remote_addr)

    t_confirm = data.timing.t_tune + data.timing.t_handshake
    {:keep_state_and_data, [{:state_timeout, t_confirm, :send_confirm}]}
  end

  def responding(:state_timeout, :send_confirm, data) do
    pdu = %PDU.LsuConf{
      caller_addr: data.link_info.caller_addr,
      called_addr: data.self_addr,
      voice: data.link_info.voice,
      snr: data.link_info[:rx_snr] || 0,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: data.waveform,
      async: true,
      tuner_time_ms: 0
    )

    transmit_frame(data.rig_id, symbols)

    link_info = Map.merge(data.link_info, %{
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF,
      we_are: :responder
    })

    new_data = %{data | link_info: link_info}
    {:next_state, :linked, new_data}
  end

  def responding({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:responding, data.remote_addr}}]}
  end

  def responding(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] response cancelled")
    {:next_state, :idle, data}
  end

  # -------------------------------------------------------------------
  # State: LINKED
  # -------------------------------------------------------------------

  def linked(:enter, _old_state, data) do
    Logger.info("ALE Link [#{data.rig_id}] LINKED with 0x#{Integer.to_string(data.remote_addr, 16)}")
    broadcast_state_change(data.rig_id, :linked, data.link_info)

    {:keep_state_and_data, [{:state_timeout, data.timing.t_activity, :activity_timeout}]}
  end

  def linked(:state_timeout, :activity_timeout, data) do
    Logger.warning("ALE Link [#{data.rig_id}] activity timeout, terminating")
    send_terminate(data, PDU.LsuTerm.reason_timeout())
    {:next_state, :idle, data}
  end

  def linked(:cast, {:rx_pdu, %PDU.LsuTerm{} = pdu}, data) do
    if pdu.caller_addr == data.remote_addr or pdu.called_addr == data.self_addr do
      Logger.info("ALE Link [#{data.rig_id}] received terminate, reason=#{pdu.reason}")
      broadcast_event(data.rig_id, :link_terminated, {:remote, pdu.reason})
      {:next_state, :idle, data}
    else
      :keep_state_and_data
    end
  end

  def linked(:cast, :stop, data) do
    Logger.info("ALE Link [#{data.rig_id}] terminating link")
    send_terminate(data, reason_to_code(:normal))
    broadcast_event(data.rig_id, :link_terminated, {:local, :normal})
    {:next_state, :idle, data}
  end

  def linked(:cast, {:terminate, reason}, data) do
    Logger.info("ALE Link [#{data.rig_id}] terminating link, reason=#{reason}")
    send_terminate(data, reason_to_code(reason))
    broadcast_event(data.rig_id, :link_terminated, {:local, reason})
    {:next_state, :idle, data}
  end

  def linked(:cast, :activity, data) do
    {:keep_state_and_data, [{:state_timeout, data.timing.t_activity, :activity_timeout}]}
  end

  def linked({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:linked, data.link_info}}]}
  end

  def linked({:call, from}, {:call, _dest_addr, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_linked}}]}
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp transmit_frame(rig_id, symbols) do
    Logger.debug("ALE Link [#{rig_id}] TX frame: #{length(symbols)} symbols")

    # First, broadcast the symbols so test harnesses can intercept
    broadcast(rig_id, {:ale_tx_symbols, rig_id, symbols})

    # Then try the actual Transmitter (if running)
    try do
      case MinuteModemCore.ALE.Transmitter.transmit(rig_id, symbols) do
        :ok ->
          broadcast_event(rig_id, :tx_complete, %{symbols: length(symbols)})
          :ok

        {:error, reason} ->
          Logger.error("ALE Link [#{rig_id}] TX failed: #{inspect(reason)}")
          broadcast_event(rig_id, :tx_failed, reason)
          {:error, reason}
      end
    catch
      :exit, {:noproc, _} ->
        # Transmitter not running - that's OK for testing
        # The symbols were already broadcast above
        Logger.debug("ALE Link [#{rig_id}] Transmitter not running, symbols broadcast only")
        broadcast_event(rig_id, :tx_complete, %{symbols: length(symbols), simulated: true})
        :ok

      :exit, reason ->
        Logger.error("ALE Link [#{rig_id}] TX error: #{inspect(reason)}")
        broadcast_event(rig_id, :tx_failed, reason)
        {:error, reason}
    end
  end

  defp send_terminate(data, reason_code) do
    pdu = %PDU.LsuTerm{
      caller_addr: data.self_addr,
      called_addr: data.remote_addr,
      reason: reason_code
    }

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: data.waveform,
      async: true
    )

    transmit_frame(data.rig_id, symbols)
  end

  defp reason_to_code(:normal), do: PDU.LsuTerm.reason_normal()
  defp reason_to_code(:timeout), do: PDU.LsuTerm.reason_timeout()
  defp reason_to_code(:busy), do: PDU.LsuTerm.reason_busy()
  defp reason_to_code(:channel_busy), do: PDU.LsuTerm.reason_channel_busy()
  defp reason_to_code(_), do: PDU.LsuTerm.reason_normal()

  defp broadcast_state_change(rig_id, state, info) do
    broadcast(rig_id, {:ale_state_change, rig_id, state, info})
  end

  defp broadcast_event(rig_id, event, payload) do
    broadcast(rig_id, {:ale_event, rig_id, event, payload})
  end

  defp broadcast(rig_id, message) do
    group = {:minutemodem, :rig, rig_id}
    for pid <- :pg.get_members(:minutemodem_pg, group) do
      send(pid, message)
    end
    :ok
  rescue
    _ -> :ok
  end
end
