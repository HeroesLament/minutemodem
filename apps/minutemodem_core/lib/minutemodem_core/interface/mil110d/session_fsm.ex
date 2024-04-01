defmodule MinuteModemCore.Interface.MIL110D.SessionFSM do
  @moduledoc """
  Session state machine for MIL-STD-188-110D Appendix A.

  Implements the connection lifecycle from A.5.1.2.1 and A.5.1.2.2:

  ## States

  - `:tcp_connected` - Socket open, waiting to exchange CONNECT
  - `:connect_sent` - We sent CONNECT, waiting for their CONNECT
  - `:ack_sent` - We sent ACK, waiting for their ACK
  - `:probing` - ACKs exchanged, modem sends PROBE
  - `:sending_setup` - Sending initial setup packets
  - `:operational` - Handshake complete, normal operation

  ## Timeouts (per spec)

  - CONNECT: 3 seconds
  - CONNECT_ACK: 3 seconds
  - CONNECTION_PROBE: 6 seconds
  - Keepalive: 2 seconds idle → send keepalive
  - Watchdog: 30 seconds no DATA → terminate
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias MinuteModemCore.Interface.MIL110D.Packet
  alias MinuteModemCore.Modem

  @protocol_version 12

  # Timeouts per spec
  @connect_timeout_ms 3_000
  @ack_timeout_ms 3_000
  @probe_timeout_ms 6_000
  @keepalive_interval_ms 2_000
  @watchdog_timeout_ms 30_000

  # ============================================================================
  # State Data
  # ============================================================================

  defstruct [
    :rig_id,
    :socket,
    :recv_buffer,
    # Timing
    :probe_sent_at,
    :round_trip_time,
    # Modem config
    :tx_data_rate,
    :tx_blocking_factor,
    :min_socket_latency,
    :max_socket_latency,
    # Keepalive tracking
    :last_packet_sent,
    :last_packet_received
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenStateMachine.start_link(__MODULE__, opts)
  end

  # ============================================================================
  # Initialization
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    socket = Keyword.fetch!(opts, :socket)

    # Set rig identifier for all log messages from this process
    Logger.metadata(rig: String.slice(rig_id, 0, 8))

    data = %__MODULE__{
      rig_id: rig_id,
      socket: socket,
      recv_buffer: <<>>,
      tx_data_rate: 4800,
      tx_blocking_factor: 576,
      min_socket_latency: 100,
      max_socket_latency: 5000,
      last_packet_sent: System.monotonic_time(:millisecond),
      last_packet_received: System.monotonic_time(:millisecond)
    }

    Logger.info("[MIL110D.Session] Started for rig #{rig_id}")
    {:ok, :tcp_connected, data}
  end

  # ============================================================================
  # State: tcp_connected
  # ============================================================================

  def tcp_connected(:enter, _old, _data) do
    Logger.debug("[MIL110D.Session] Entered tcp_connected")
    :keep_state_and_data
  end

  def tcp_connected(:info, :socket_ready, data) do
    :inet.setopts(data.socket, [active: true])

    case send_packet(data, Packet.connect(protocol_version: @protocol_version)) do
      {:ok, new_data} ->
        {:next_state, :connect_sent, new_data,
         [{:state_timeout, @connect_timeout_ms, :connect_timeout}]}

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Failed to send CONNECT: #{inspect(reason)}")
        {:stop, :send_failed}
    end
  end

  def tcp_connected(:info, {:tcp, _socket, tcp_data}, data) do
    {:keep_state, buffer_data(data, tcp_data)}
  end

  def tcp_connected(:info, {:tcp_closed, _socket}, _data) do
    {:stop, :normal}
  end

  # ============================================================================
  # State: connect_sent
  # ============================================================================

  def connect_sent(:enter, _old, data) do
    Logger.debug("[MIL110D.Session] Entered connect_sent")
    # Check if CONNECT is already buffered (arrived before we entered this state)
    if byte_size(data.recv_buffer) > 0 do
      {:keep_state, data, [{:timeout, 0, :check_buffer}]}
    else
      :keep_state_and_data
    end
  end

  def connect_sent(:timeout, :check_buffer, data) do
    # Process buffered data as if it just arrived
    process_connect_sent_buffer(data)
  end

  def connect_sent(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    process_connect_sent_buffer(data)
  end

  defp process_connect_sent_buffer(data) do
    case Packet.parse(data.recv_buffer) do
      {:ok, {:connect, version}, rest} when version == @protocol_version ->
        data = %{data | recv_buffer: rest}

        case send_packet(data, Packet.connect_ack(protocol_version: @protocol_version)) do
          {:ok, new_data} ->
            {:next_state, :ack_sent, new_data,
             [{:state_timeout, @ack_timeout_ms, :ack_timeout}]}

          {:error, reason} ->
            Logger.error("[MIL110D.Session] Failed to send ACK: #{inspect(reason)}")
            {:stop, :send_failed}
        end

      {:ok, {:connect, version}, _rest} ->
        Logger.error("[MIL110D.Session] Version mismatch: #{version} != #{@protocol_version}")
        {:stop, :version_mismatch}

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def connect_sent(:state_timeout, :connect_timeout, _data) do
    Logger.error("[MIL110D.Session] CONNECT timeout")
    {:stop, :connect_timeout}
  end

  def connect_sent(:info, {:tcp_closed, _socket}, _data), do: {:stop, :normal}

  # ============================================================================
  # State: ack_sent
  # ============================================================================

  def ack_sent(:enter, _old, data) do
    Logger.debug("[MIL110D.Session] Entered ack_sent")
    # Check if CONNECT_ACK is already buffered (arrived with CONNECT)
    if byte_size(data.recv_buffer) > 0 do
      {:keep_state, data, [{:timeout, 0, :check_buffer}]}
    else
      :keep_state_and_data
    end
  end

  def ack_sent(:timeout, :check_buffer, data) do
    # Process buffered data as if it just arrived
    process_ack_sent_buffer(data)
  end

  def ack_sent(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    process_ack_sent_buffer(data)
  end

  defp process_ack_sent_buffer(data) do
    case Packet.parse(data.recv_buffer) do
      {:ok, {:connect_ack, @protocol_version}, rest} ->
        {:next_state, :probing, %{data | recv_buffer: rest}}

      {:ok, {:connect_ack, version}, _rest} ->
        Logger.error("[MIL110D.Session] ACK version mismatch: #{version}")
        {:stop, :version_mismatch}

      {:ok, :connection_probe, rest} ->
        # Client sent probe early - we got both ACK and PROBE in same batch
        # Transition to probing and process it there
        Logger.debug("[MIL110D.Session] Got early PROBE, transitioning to probing")
        {:next_state, :probing, %{data | recv_buffer: rest}}

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def ack_sent(:state_timeout, :ack_timeout, _data) do
    Logger.error("[MIL110D.Session] ACK timeout")
    {:stop, :ack_timeout}
  end

  def ack_sent(:info, {:tcp_closed, _socket}, _data), do: {:stop, :normal}

  # ============================================================================
  # State: probing
  # ============================================================================

  def probing(:enter, _old, data) do
    Logger.debug("[MIL110D.Session] Sending CONNECTION_PROBE")
    probe_time = System.monotonic_time(:millisecond)

    case send_packet(data, Packet.connection_probe()) do
      {:ok, new_data} ->
        new_data = %{new_data | probe_sent_at: probe_time}
        # Check if probe response is already buffered
        if byte_size(new_data.recv_buffer) > 0 do
          {:keep_state, new_data, [{:timeout, 0, :check_buffer}, {:state_timeout, @probe_timeout_ms, :probe_timeout}]}
        else
          {:keep_state, new_data, [{:state_timeout, @probe_timeout_ms, :probe_timeout}]}
        end

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Failed to send PROBE: #{inspect(reason)}")
        {:stop, :send_failed}
    end
  end

  def probing(:timeout, :check_buffer, data) do
    process_probing_buffer(data)
  end

  def probing(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    process_probing_buffer(data)
  end

  defp process_probing_buffer(data) do
    case Packet.parse(data.recv_buffer) do
      {:ok, :connection_probe, rest} ->
        rtt = System.monotonic_time(:millisecond) - data.probe_sent_at
        Logger.info("[MIL110D.Session] RTT: #{rtt}ms")

        if rtt > data.max_socket_latency do
          Logger.error("[MIL110D.Session] RTT exceeds max latency")
          {:stop, :latency_exceeded}
        else
          {:next_state, :sending_setup, %{data | recv_buffer: rest, round_trip_time: rtt}}
        end

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def probing(:state_timeout, :probe_timeout, _data) do
    Logger.error("[MIL110D.Session] PROBE timeout")
    {:stop, :probe_timeout}
  end

  def probing(:info, {:tcp_closed, _socket}, _data), do: {:stop, :normal}

  # ============================================================================
  # State: sending_setup
  # ============================================================================

  def sending_setup(:enter, _old, _data) do
    Logger.debug("[MIL110D.Session] Sending setup packets")
    # Use a zero timeout to trigger send immediately after enter
    {:keep_state_and_data, [{:timeout, 0, :do_send_setup}]}
  end

  def sending_setup(:timeout, :do_send_setup, data) do
    with {:ok, data} <- send_initial_setup(data),
         {:ok, data} <- send_tx_setup(data),
         {:ok, data} <- send_tx_status(data, :flushed),
         {:ok, data} <- send_carrier_detect(data) do
      {:next_state, :operational, data}
    else
      {:error, reason} ->
        Logger.error("[MIL110D.Session] Setup failed: #{inspect(reason)}")
        {:stop, :send_failed}
    end
  end

  def sending_setup(:info, {:tcp, _socket, tcp_data}, data) do
    # Buffer any incoming data while sending setup
    {:keep_state, buffer_data(data, tcp_data)}
  end

  def sending_setup(:info, {:tcp_closed, _socket}, _data), do: {:stop, :normal}

  # ============================================================================
  # State: operational
  # ============================================================================

  def operational(:enter, _old, data) do
    Logger.info("[MIL110D.Session] Operational for rig #{data.rig_id}")
    Modem.subscribe(data.rig_id)
    {:keep_state, data, [{:state_timeout, @keepalive_interval_ms, :keepalive_check}]}
  end

  def operational(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    data = %{data | last_packet_received: System.monotonic_time(:millisecond)}

    case process_packets(data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:state_timeout, @keepalive_interval_ms, :keepalive_check}]}

      {:error, reason} ->
        Logger.error("[MIL110D.Session] Packet error: #{inspect(reason)}")
        {:stop, :protocol_error}
    end
  end

  def operational(:info, {:modem, event}, data) do
    case translate_modem_event(event, data) do
      {:ok, new_data} -> {:keep_state, new_data}
      {:error, _} -> {:keep_state, data}
    end
  end

  def operational(:state_timeout, :keepalive_check, data) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - data.last_packet_received > @watchdog_timeout_ms ->
        Logger.error("[MIL110D.Session] Watchdog timeout")
        {:stop, :watchdog_timeout}

      now - data.last_packet_sent > @keepalive_interval_ms ->
        case send_packet(data, Packet.data_keepalive()) do
          {:ok, new_data} ->
            {:keep_state, new_data, [{:state_timeout, @keepalive_interval_ms, :keepalive_check}]}

          {:error, _} ->
            {:stop, :send_failed}
        end

      true ->
        {:keep_state_and_data, [{:state_timeout, @keepalive_interval_ms, :keepalive_check}]}
    end
  end

  def operational(:info, {:tcp_closed, _socket}, data) do
    Logger.info("[MIL110D.Session] Connection closed for rig #{data.rig_id}")
    {:stop, :normal}
  end

  # ============================================================================
  # Termination
  # ============================================================================

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("[MIL110D.Session] Terminating: #{inspect(reason)}")
    if data.socket, do: :gen_tcp.close(data.socket)
    Modem.unsubscribe(data.rig_id)
    :ok
  end

  # ============================================================================
  # Packet Processing (operational state)
  # ============================================================================

  defp process_packets(data) do
    case Packet.parse(data.recv_buffer) do
      {:ok, packet, rest} ->
        case handle_packet(packet, data) do
          {:ok, new_data} ->
            process_packets(%{new_data | recv_buffer: rest})

          {:error, _} = err ->
            err
        end

      {:incomplete, _} ->
        {:ok, data}

      {:error, _} = err ->
        err
    end
  end

  defp handle_packet({:data, payload_cmd, payload}, data) do
    handle_payload_command(payload_cmd, payload, data)
  end

  defp handle_packet(:keepalive, data) do
    # Keepalive received - watchdog already reset by caller
    {:ok, data}
  end

  defp handle_packet({:error_packet, code}, data) do
    Logger.warning("[MIL110D.Session] Received error packet: #{code}")
    {:ok, data}
  end

  defp handle_packet(unknown, data) do
    Logger.warning("[MIL110D.Session] Unknown packet: #{inspect(unknown)}")
    {:ok, data}
  end

  # ============================================================================
  # Payload Command Handlers
  # ============================================================================

  defp handle_payload_command(:transmit_arm, _payload, data) do
    Logger.debug("[MIL110D.Session] Processing ARM command for rig #{data.rig_id}")
    case Modem.arm_tx(data.rig_id) do
      {:ok, status} ->
        Logger.debug("[MIL110D.Session] ARM succeeded: #{inspect(status)}")
        send_tx_status(data, status)

      {:error, reason} ->
        Logger.warning("[MIL110D.Session] ARM failed: #{inspect(reason)}")
        send_tx_status(data, :flushed)
    end
  end

  defp handle_payload_command(:transmit_start, _payload, data) do
    case Modem.start_tx(data.rig_id) do
      {:ok, :started} ->
        send_tx_status(data, :started)

      {:ok, :starting} ->
        # Will get status update via event
        {:ok, data}

      {:error, reason} ->
        Logger.warning("[MIL110D.Session] START failed: #{reason}")
        send_tx_nack(data, reason)
    end
  end

  defp handle_payload_command(:tx_data, payload, data) do
    # Payload format: order (1 byte) + data
    <<order::8, user_data::binary>> = payload
    order_atom = Packet.decode_order(order)

    case Modem.tx_data(data.rig_id, user_data, order: order_atom) do
      :ok ->
        {:ok, data}

      {:error, :queue_full} ->
        # Per spec: TCP will block. We should signal backpressure.
        Logger.warning("[MIL110D.Session] TX queue full")
        {:ok, data}

      {:error, reason} ->
        send_tx_nack(data, reason)
    end
  end

  defp handle_payload_command(:abort_tx, _payload, data) do
    Modem.abort_tx(data.rig_id)
    {:ok, data}
  end

  defp handle_payload_command(:abort_rx, _payload, data) do
    Modem.abort_rx(data.rig_id)
    {:ok, data}
  end

  defp handle_payload_command(:request_tx_status, _payload, data) do
    status = Modem.tx_status(data.rig_id)
    send_tx_status(data, status.state)
  end

  defp handle_payload_command(cmd, _payload, data) do
    Logger.warning("[MIL110D.Session] Unhandled command: #{inspect(cmd)}")
    {:ok, data}
  end

  # ============================================================================
  # Modem Event Translation
  # ============================================================================

  defp translate_modem_event({:tx_status, status}, data) do
    send_tx_status(data, status.state)
  end

  defp translate_modem_event(:tx_underrun, data) do
    send_tx_nack(data, :underrun)
  end

  defp translate_modem_event({:rx_carrier, :detected, params}, data) do
    packet = Packet.carrier_detect(%{
      state: :carrier_detected,
      data_rate: params.data_rate,
      blocking_factor: params.blocking_factor
    })

    send_packet(data, packet)
  end

  defp translate_modem_event({:rx_carrier, :lost, _params}, data) do
    packet = Packet.carrier_detect(%{
      state: :no_carrier,
      data_rate: 0,
      blocking_factor: 0
    })

    send_packet(data, packet)
  end

  defp translate_modem_event({:rx_data, payload, order}, data) do
    Logger.debug("[MIL110D.Session] Sending rx_data to client: #{byte_size(payload)} bytes, order=#{order}")
    if byte_size(payload) > 0 do
      preview = payload |> :binary.bin_to_list() |> Enum.take(20) |> inspect()
      Logger.debug("[MIL110D.Session] First 20 bytes: #{preview}")
      # Also show as string if printable
      try do
        Logger.debug("[MIL110D.Session] As string: #{inspect(payload)}")
      rescue
        _ -> :ok
      end
    end
    packet = Packet.rx_data(payload, order)
    Logger.debug("[MIL110D.Session] Packet size: #{byte_size(packet)}, first 10: #{inspect(:binary.bin_to_list(packet) |> Enum.take(10))}")
    send_packet(data, packet)
  end

  defp translate_modem_event(_event, data) do
    {:ok, data}
  end

  # ============================================================================
  # Packet Sending
  # ============================================================================

  defp send_packet(data, packet_binary) do
    case :gen_tcp.send(data.socket, packet_binary) do
      :ok ->
        {:ok, %{data | last_packet_sent: System.monotonic_time(:millisecond)}}

      {:error, _} = err ->
        err
    end
  end

  defp send_initial_setup(data) do
    packet = Packet.initial_setup(%{
      round_trip_time: data.round_trip_time || 0,
      min_socket_latency: data.min_socket_latency,
      max_socket_latency: data.max_socket_latency,
      sync_flag: 0,
      async_data_bits: 8,
      async_stop_bits: 1,
      async_parity: 0,
      async_data_mode: 0
    })

    send_packet(data, packet)
  end

  defp send_tx_setup(data) do
    packet = Packet.tx_setup(%{
      data_rate: data.tx_data_rate,
      blocking_factor: data.tx_blocking_factor
    })

    send_packet(data, packet)
  end

  defp send_tx_status(data, state) do
    status = Modem.tx_status(data.rig_id)

    packet = Packet.tx_status(%{
      state: state,
      queued_bytes: Map.get(status, :queued_bytes, 0),
      free_bytes: Map.get(status, :free_bytes, 16384),
      serial_fifo_space: 0
    })

    send_packet(data, packet)
  end

  defp send_tx_nack(data, reason) do
    packet = Packet.tx_nack(reason)
    send_packet(data, packet)
  end

  defp send_carrier_detect(data) do
    rx_status = Modem.rx_status(data.rig_id)

    packet = case rx_status.state do
      :no_carrier ->
        Packet.carrier_detect(%{state: :no_carrier, data_rate: 0, blocking_factor: 0})

      state when state in [:carrier_detected, :receiving] ->
        Packet.carrier_detect(%{
          state: :carrier_detected,
          data_rate: rx_status.data_rate,
          blocking_factor: rx_status.blocking_factor
        })
    end

    send_packet(data, packet)
  end

  # ============================================================================
  # Buffer Management
  # ============================================================================

  defp buffer_data(data, tcp_data) do
    %{data | recv_buffer: data.recv_buffer <> tcp_data}
  end
end
