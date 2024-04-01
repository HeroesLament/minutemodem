defmodule MinuteModemClient.DTE.Client do
  @moduledoc """
  DTE client for MIL-STD-188-110D Appendix A.

  Implements the DTE side of the protocol as a GenStateMachine.

  ## Handshake Sequence (per A.5.1.2.1)

  1. TCP connected
  2. DTE sends CONNECT, Modem sends CONNECT (simultaneous)
  3. DTE receives CONNECT → sends CONNECT_ACK
  4. DTE receives CONNECT_ACK → waits for probe
  5. DTE receives CONNECTION_PROBE → echoes it back
  6. DTE receives setup packets → operational

  ## States

  - `:connecting` - TCP connected, sent CONNECT, waiting for modem's CONNECT
  - `:connect_received` - Got modem's CONNECT, sent ACK, waiting for modem's ACK
  - `:waiting_probe` - Got modem's ACK, waiting for CONNECTION_PROBE
  - `:operational` - Fully connected, can send/receive data
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  # State data
  defstruct [
    :socket,
    :owner,
    :recv_buffer,
    :keepalive_timer
  ]

  # Timeouts per spec
  @connect_timeout 3_000
  @probe_timeout 6_000
  @keepalive_interval 2_000

  # Protocol version
  @protocol_version 12

  # Preamble bytes
  @preamble <<0x49, 0x50, 0x55>>

  # Packet types
  @type_connect 0x01
  @type_connect_ack 0x02
  @type_connection_probe 0x03
  @type_data 0x04
  @type_error 0xFF

  # Payload commands
  @cmd_tx_data 0x01
  @cmd_rx_data 0x02
  @cmd_transmit_arm 0x03
  @cmd_transmit_start 0x04
  @cmd_transmit_status 0x05
  @cmd_tx_data_nack 0x06
  @cmd_carrier_detect 0x07
  @cmd_initial_setup 0x0A
  @cmd_abort_tx 0x0B
  @cmd_abort_rx 0x0C

  # ===========================================================================
  # Public API
  # ===========================================================================

  def connect(host, port, owner) do
    GenStateMachine.start_link(__MODULE__, {host, port, owner})
  end

  def disconnect(pid) do
    GenStateMachine.cast(pid, :disconnect)
  end

  def arm(pid) do
    GenStateMachine.cast(pid, :arm)
  end

  def start_tx(pid) do
    GenStateMachine.cast(pid, :start_tx)
  end

  def send_data(pid, data, order) do
    GenStateMachine.cast(pid, {:send_data, data, order})
  end

  def abort(pid) do
    GenStateMachine.cast(pid, :abort)
  end

  # ===========================================================================
  # GenStateMachine Callbacks
  # ===========================================================================

  @impl true
  def init({host, port, owner}) do
    host_charlist = if is_binary(host), do: String.to_charlist(host), else: host

    case :gen_tcp.connect(host_charlist, port, [:binary, active: true, packet: :raw], 5000) do
      {:ok, socket} ->
        Logger.info("[DTE.Client] TCP connected to #{host}:#{port}")

        data = %__MODULE__{
          socket: socket,
          owner: owner,
          recv_buffer: <<>>
        }

        # Send CONNECT immediately
        send_packet(socket, @type_connect, <<@protocol_version::8>>)
        Logger.debug("[DTE.Client] Sent CONNECT (v#{@protocol_version})")

        {:ok, :connecting, data, [{:state_timeout, @connect_timeout, :connect_timeout}]}

      {:error, reason} ->
        Logger.error("[DTE.Client] TCP connect failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # ===========================================================================
  # State: connecting
  # Waiting for modem's CONNECT packet
  # ===========================================================================

  def connecting(:enter, _old_state, data) do
    Logger.debug("[DTE.Client] Entered :connecting")
    notify(data.owner, {:dte_client_state, :connecting})
    :keep_state_and_data
  end

  def connecting(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)

    case parse_packet(data.recv_buffer) do
      {:ok, {:connect, version}, rest} when version == @protocol_version ->
        Logger.debug("[DTE.Client] Got CONNECT (v#{version}), sending CONNECT_ACK")
        send_packet(data.socket, @type_connect_ack, <<@protocol_version::8>>)
        {:next_state, :connect_received, %{data | recv_buffer: rest},
         [{:state_timeout, @connect_timeout, :ack_timeout}]}

      {:ok, {:connect, version}, _rest} ->
        Logger.error("[DTE.Client] Version mismatch: got #{version}, expected #{@protocol_version}")
        {:stop, :version_mismatch}

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def connecting(:state_timeout, :connect_timeout, _data) do
    Logger.error("[DTE.Client] Timeout waiting for CONNECT")
    {:stop, :connect_timeout}
  end

  def connecting(:info, {:tcp_closed, _}, _data) do
    Logger.info("[DTE.Client] Connection closed during handshake")
    {:stop, :normal}
  end

  def connecting(:info, {:tcp_error, _, reason}, _data) do
    Logger.error("[DTE.Client] TCP error: #{inspect(reason)}")
    {:stop, reason}
  end

  # ===========================================================================
  # State: connect_received
  # Got modem's CONNECT, sent our ACK, waiting for modem's CONNECT_ACK
  # ===========================================================================

  def connect_received(:enter, _old_state, data) do
    Logger.debug("[DTE.Client] Entered :connect_received")
    notify(data.owner, {:dte_client_state, :connect_received})
    :keep_state_and_data
  end

  def connect_received(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)

    case parse_packet(data.recv_buffer) do
      {:ok, {:connect_ack, version}, rest} when version == @protocol_version ->
        Logger.debug("[DTE.Client] Got CONNECT_ACK (v#{version}), waiting for probe")
        {:next_state, :waiting_probe, %{data | recv_buffer: rest},
         [{:state_timeout, @probe_timeout, :probe_timeout}]}

      {:ok, {:connect_ack, version}, _rest} ->
        Logger.error("[DTE.Client] ACK version mismatch: got #{version}")
        {:stop, :version_mismatch}

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def connect_received(:state_timeout, :ack_timeout, _data) do
    Logger.error("[DTE.Client] Timeout waiting for CONNECT_ACK")
    {:stop, :ack_timeout}
  end

  def connect_received(:info, {:tcp_closed, _}, _data), do: {:stop, :normal}
  def connect_received(:info, {:tcp_error, _, reason}, _data), do: {:stop, reason}

  # ===========================================================================
  # State: waiting_probe
  # Got ACKs exchanged, waiting for modem's CONNECTION_PROBE
  # ===========================================================================

  def waiting_probe(:enter, _old_state, data) do
    Logger.debug("[DTE.Client] Entered :waiting_probe, buffer size: #{byte_size(data.recv_buffer)}")
    notify(data.owner, {:dte_client_state, :waiting_probe})
    # Check if probe is already buffered (arrived with ACK)
    if byte_size(data.recv_buffer) > 0 do
      Logger.debug("[DTE.Client] Buffer has data, checking for probe")
      {:keep_state, data, [{:timeout, 0, :check_buffer}]}
    else
      :keep_state_and_data
    end
  end

  def waiting_probe(:timeout, :check_buffer, data) do
    Logger.debug("[DTE.Client] check_buffer, buffer: #{inspect(data.recv_buffer)}")
    case parse_packet(data.recv_buffer) do
      {:ok, :connection_probe, rest} ->
        Logger.debug("[DTE.Client] Got CONNECTION_PROBE (from buffer), echoing back")
        send_packet(data.socket, @type_connection_probe, <<>>)
        {:next_state, :receiving_setup, %{data | recv_buffer: rest},
         [{:state_timeout, @probe_timeout, :setup_timeout}]}

      {:incomplete, reason} ->
        Logger.debug("[DTE.Client] Parse incomplete: #{inspect(reason)}")
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}

      other ->
        Logger.debug("[DTE.Client] Parse returned unexpected: #{inspect(other)}")
        {:keep_state, data}
    end
  end

  def waiting_probe(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)

    case parse_packet(data.recv_buffer) do
      {:ok, :connection_probe, rest} ->
        Logger.debug("[DTE.Client] Got CONNECTION_PROBE, echoing back")
        send_packet(data.socket, @type_connection_probe, <<>>)
        # Now wait for setup packets, then go operational
        {:next_state, :receiving_setup, %{data | recv_buffer: rest},
         [{:state_timeout, @probe_timeout, :setup_timeout}]}

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  def waiting_probe(:state_timeout, :probe_timeout, _data) do
    Logger.error("[DTE.Client] Timeout waiting for CONNECTION_PROBE")
    {:stop, :probe_timeout}
  end

  def waiting_probe(:info, {:tcp_closed, _}, _data), do: {:stop, :normal}
  def waiting_probe(:info, {:tcp_error, _, reason}, _data), do: {:stop, reason}

  # ===========================================================================
  # State: receiving_setup
  # Got probe, waiting for Initial Setup, Tx Setup, Tx Status, Carrier Detect
  # ===========================================================================

  def receiving_setup(:enter, _old_state, data) do
    Logger.debug("[DTE.Client] Entered :receiving_setup")
    notify(data.owner, {:dte_client_state, :receiving_setup})
    :keep_state_and_data
  end

  def receiving_setup(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    process_setup_packets(data)
  end

  def receiving_setup(:state_timeout, :setup_timeout, _data) do
    Logger.error("[DTE.Client] Timeout waiting for setup packets")
    {:stop, :setup_timeout}
  end

  def receiving_setup(:info, {:tcp_closed, _}, _data), do: {:stop, :normal}
  def receiving_setup(:info, {:tcp_error, _, reason}, _data), do: {:stop, reason}

  defp process_setup_packets(data) do
    case parse_packet(data.recv_buffer) do
      {:ok, {:data, payload}, rest} ->
        handle_setup_data(payload, %{data | recv_buffer: rest})

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error in setup: #{inspect(reason)}")
        {:stop, :parse_error}
    end
  end

  defp handle_setup_data(<<@cmd_initial_setup::8, _rest::binary>>, data) do
    Logger.debug("[DTE.Client] Got Initial Setup")
    process_setup_packets(data)
  end

  defp handle_setup_data(<<0x09::8, _rest::binary>>, data) do
    # Tx Setup (0x09)
    Logger.debug("[DTE.Client] Got Tx Setup")
    process_setup_packets(data)
  end

  defp handle_setup_data(<<@cmd_transmit_status::8, _rest::binary>>, data) do
    Logger.debug("[DTE.Client] Got Tx Status")
    process_setup_packets(data)
  end

  defp handle_setup_data(<<@cmd_carrier_detect::8, _rest::binary>>, data) do
    Logger.info("[DTE.Client] Got Carrier Detect - now operational!")

    # Start keepalive timer
    timer = Process.send_after(self(), :send_keepalive, @keepalive_interval)
    {:next_state, :operational, %{data | keepalive_timer: timer}}
  end

  defp handle_setup_data(payload, data) do
    Logger.debug("[DTE.Client] Unknown setup payload: #{inspect(payload)}")
    process_setup_packets(data)
  end

  # ===========================================================================
  # State: operational
  # Fully connected, can send/receive data
  # ===========================================================================

  def operational(:enter, _old_state, data) do
    Logger.debug("[DTE.Client] Entered :operational")
    notify(data.owner, {:dte_client_state, :operational})
    :keep_state_and_data
  end

  # --- Commands from owner ---

  def operational(:cast, :arm, data) do
    send_data_packet(data.socket, <<@cmd_transmit_arm::8>>)
    :keep_state_and_data
  end

  def operational(:cast, :start_tx, data) do
    send_data_packet(data.socket, <<@cmd_transmit_start::8>>)
    :keep_state_and_data
  end

  def operational(:cast, {:send_data, payload, order}, data) do
    order_byte = encode_order(order)
    send_data_packet(data.socket, <<@cmd_tx_data::8, order_byte::8, payload::binary>>)
    :keep_state_and_data
  end

  def operational(:cast, :abort, data) do
    send_data_packet(data.socket, <<@cmd_abort_tx::8>>)
    send_data_packet(data.socket, <<@cmd_abort_rx::8>>)
    :keep_state_and_data
  end

  def operational(:cast, :disconnect, data) do
    cleanup(data)
    {:stop, :normal}
  end

  # --- Incoming packets ---

  def operational(:info, {:tcp, _socket, tcp_data}, data) do
    data = buffer_data(data, tcp_data)
    process_operational_packets(data)
  end

  def operational(:info, :send_keepalive, data) do
    # Empty DATA packet as keepalive
    send_packet(data.socket, @type_data, <<>>)
    timer = Process.send_after(self(), :send_keepalive, @keepalive_interval)
    {:keep_state, %{data | keepalive_timer: timer}}
  end

  def operational(:info, {:tcp_closed, _}, data) do
    Logger.info("[DTE.Client] Connection closed")
    notify(data.owner, {:dte_disconnected, :closed})
    {:stop, :normal}
  end

  def operational(:info, {:tcp_error, _, reason}, data) do
    Logger.error("[DTE.Client] TCP error: #{inspect(reason)}")
    notify(data.owner, {:dte_disconnected, reason})
    {:stop, reason}
  end

  defp process_operational_packets(data) do
    case parse_packet(data.recv_buffer) do
      {:ok, {:data, payload}, rest} ->
        handle_data_payload(payload, data.owner)
        process_operational_packets(%{data | recv_buffer: rest})

      {:ok, {:error, code}, rest} ->
        Logger.error("[DTE.Client] Error packet: #{code}")
        notify(data.owner, {:dte_error, code})
        process_operational_packets(%{data | recv_buffer: rest})

      {:incomplete, _} ->
        {:keep_state, data}

      {:error, reason} ->
        Logger.error("[DTE.Client] Parse error: #{inspect(reason)}")
        {:keep_state, data}
    end
  end

  defp handle_data_payload(<<>>, _owner) do
    # Keepalive, ignore
    :ok
  end

  defp handle_data_payload(<<@cmd_transmit_status::8, tx_state::8, _rest::binary>>, owner) do
    notify(owner, {:dte_tx_state, decode_tx_state(tx_state)})
  end

  defp handle_data_payload(<<@cmd_tx_data_nack::8, reason::8>>, owner) do
    notify(owner, {:dte_tx_nack, decode_nack_reason(reason)})
  end

  # Parse ARQ framing and send structured data to scene
  defp handle_data_payload(<<@cmd_rx_data::8, order::8, payload::binary>>, owner) do
    order_atom = decode_order(order)

    # Parse ARQ frame: <<type::8, seq::8, data::binary>>
    parsed = case payload do
      <<0x00, seq::8, data::binary>> ->
        # Data frame - seq is sequence number, data is the actual payload
        %{type: :data, seq: seq, data: data}
      <<0x01, seq::8, _rest::binary>> ->
        # ACK frame
        %{type: :ack, seq: seq, data: nil}
      _ ->
        # Unknown format - pass through raw
        %{type: :raw, seq: nil, data: payload}
    end

    notify(owner, {:dte_rx_data, parsed, order_atom})
    if order_atom in [:last, :first_and_last] do
      notify(owner, {:dte_rx_complete})
    end
  end

  defp handle_data_payload(<<@cmd_carrier_detect::8, carrier_state::8, _rest::binary>>, owner) do
    case carrier_state do
      0x01 -> notify(owner, {:dte_carrier, :detected})
      0x00 -> notify(owner, {:dte_carrier, :lost})
      _ -> :ok
    end
  end

  defp handle_data_payload(payload, _owner) do
    Logger.debug("[DTE.Client] Unknown payload: #{inspect(payload, limit: 20)}")
  end

  # ===========================================================================
  # Catch-all for unhandled events in any state
  # ===========================================================================

  def handle_event(:cast, :disconnect, _state, data) do
    cleanup(data)
    {:stop, :normal}
  end

  def handle_event(:cast, _msg, state, _data) do
    Logger.debug("[DTE.Client] Ignoring cast in state #{state}")
    :keep_state_and_data
  end

  def handle_event(:info, msg, state, _data) do
    Logger.debug("[DTE.Client] Ignoring info #{inspect(msg)} in state #{state}")
    :keep_state_and_data
  end

  # ===========================================================================
  # Packet Building & Parsing
  # ===========================================================================

  defp send_packet(socket, type, payload) do
    packet = build_packet(type, payload)
    :gen_tcp.send(socket, packet)
  end

  defp send_data_packet(socket, payload) do
    send_packet(socket, @type_data, payload)
  end

  defp build_packet(type, payload) do
    size = byte_size(payload)
    header_data = <<@preamble::binary, type::8, size::16-big>>
    header_crc = crc16(header_data)

    if size == 0 do
      <<header_data::binary, header_crc::16-big>>
    else
      payload_crc = crc16(payload)
      <<header_data::binary, header_crc::16-big, payload::binary, payload_crc::16-big>>
    end
  end

  defp buffer_data(data, tcp_data) do
    %{data | recv_buffer: data.recv_buffer <> tcp_data}
  end

  defp parse_packet(<<0x49, 0x50, 0x55, type::8, size::16-big, _header_crc::16-big, rest::binary>>) do
    if size == 0 do
      {:ok, decode_packet_type(type, <<>>), rest}
    else
      total_needed = size + 2  # payload + CRC

      if byte_size(rest) >= total_needed do
        <<payload::binary-size(size), _payload_crc::16-big, remaining::binary>> = rest
        {:ok, decode_packet_type(type, payload), remaining}
      else
        {:incomplete, :need_more}
      end
    end
  end

  defp parse_packet(<<0x49, 0x50, 0x55, _rest::binary>> = buffer) when byte_size(buffer) < 8 do
    {:incomplete, :need_header}
  end

  defp parse_packet(buffer) when byte_size(buffer) < 3 do
    {:incomplete, :need_header}
  end

  defp parse_packet(<<_, rest::binary>>) do
    # Skip non-preamble byte and try again
    parse_packet(rest)
  end

  defp parse_packet(<<>>) do
    {:incomplete, :empty}
  end

  defp decode_packet_type(@type_connect, <<version::8>>), do: {:connect, version}
  defp decode_packet_type(@type_connect_ack, <<version::8>>), do: {:connect_ack, version}
  defp decode_packet_type(@type_connection_probe, _), do: :connection_probe
  defp decode_packet_type(@type_data, payload), do: {:data, payload}
  defp decode_packet_type(@type_error, <<code::8>>), do: {:error, code}
  defp decode_packet_type(type, payload), do: {:unknown, type, payload}

  # ===========================================================================
  # Encoding/Decoding Helpers
  # ===========================================================================

  defp encode_order(:first), do: 0x00
  defp encode_order(:continuation), do: 0x01
  defp encode_order(:last), do: 0x02
  defp encode_order(:first_and_last), do: 0x03
  defp encode_order(_), do: 0x01

  defp decode_order(0x00), do: :first
  defp decode_order(0x01), do: :continuation
  defp decode_order(0x02), do: :last
  defp decode_order(0x03), do: :first_and_last
  defp decode_order(_), do: :continuation

  defp decode_tx_state(0x00), do: :flushed
  defp decode_tx_state(0x01), do: :armed_port_not_ready
  defp decode_tx_state(0x02), do: :armed
  defp decode_tx_state(0x03), do: :started
  defp decode_tx_state(0x04), do: :draining
  defp decode_tx_state(0x05), do: :draining_forced
  defp decode_tx_state(_), do: :unknown

  defp decode_nack_reason(0x01), do: :underrun
  defp decode_nack_reason(0x02), do: :not_armed
  defp decode_nack_reason(0x03), do: :queue_full
  defp decode_nack_reason(_), do: :unknown

  # ===========================================================================
  # CRC-16-CCITT
  # ===========================================================================

  defp crc16(data), do: crc16(data, 0xFFFF)

  defp crc16(<<>>, crc), do: crc

  defp crc16(<<byte::8, rest::binary>>, crc) do
    import Bitwise
    crc = bxor(crc, byte <<< 8)

    crc =
      Enum.reduce(0..7, crc, fn _, acc ->
        if (acc &&& 0x8000) != 0 do
          bxor(acc <<< 1, 0x1021) &&& 0xFFFF
        else
          (acc <<< 1) &&& 0xFFFF
        end
      end)

    crc16(rest, crc)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp notify(owner, event) do
    send(owner, event)
  end

  defp cleanup(data) do
    if data.keepalive_timer, do: Process.cancel_timer(data.keepalive_timer)
    if data.socket, do: :gen_tcp.close(data.socket)
  end
end
