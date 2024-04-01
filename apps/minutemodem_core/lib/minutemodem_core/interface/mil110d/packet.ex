defmodule MinuteModemCore.Interface.MIL110D.Packet do
  @moduledoc """
  Packet encoding and decoding for MIL-STD-188-110D Appendix A.

  ## Packet Format (A.5.1.1)

      ┌─────────────────────────────────────────────────────┐
      │ Preamble (3 bytes): 0x49 0x50 0x55                  │
      │ Type (1 byte)                                       │
      │ Payload Size (2 bytes, big-endian, 0..4086)        │
      │ Header CRC (2 bytes)                                │
      ├─────────────────────────────────────────────────────┤
      │ Payload (0..4086 bytes)                             │
      │ Payload CRC (2 bytes, if payload present)           │
      └─────────────────────────────────────────────────────┘

  ## Packet Types (Table A-I)

      0x01 - CONNECT
      0x02 - CONNECT_ACK
      0x03 - CONNECTION_PROBE
      0x04 - DATA (with payload command)
      0xFF - ERROR

  ## Payload Commands (Table A-II, inside DATA packets)

      0x01 - TX Data
      0x02 - RX Data
      0x03 - Transmit ARM
      0x04 - Transmit Start
      0x05 - Transmit Status
      0x06 - TX Data NACK
      0x07 - Carrier Detect
      0x08 - Request TX Status
      0x09 - TX Setup
      0x0A - Initial Setup
      0x0B - Abort TX
      0x0C - Abort RX
  """

  import Bitwise

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
  @cmd_request_tx_status 0x08
  @cmd_tx_setup 0x09
  @cmd_initial_setup 0x0A
  @cmd_abort_tx 0x0B
  @cmd_abort_rx 0x0C

  # TX Status states
  @tx_state_flushed 0x00
  @tx_state_armed_port_not_ready 0x01
  @tx_state_armed_port_ready 0x02
  @tx_state_started 0x03
  @tx_state_draining_ok 0x04
  @tx_state_draining_forced 0x05

  # Carrier detect states
  @carrier_no_carrier 0x00
  @carrier_detected 0x01

  # Packet order flags
  @order_first 0x00
  @order_continuation 0x01
  @order_last 0x02
  @order_first_and_last 0x03

  # ============================================================================
  # Packet Building
  # ============================================================================

  @doc "Build a CONNECT packet"
  def connect(opts \\ []) do
    version = Keyword.get(opts, :protocol_version, 1)
    build_packet(@type_connect, <<version::8>>)
  end

  @doc "Build a CONNECT_ACK packet"
  def connect_ack(opts \\ []) do
    version = Keyword.get(opts, :protocol_version, 1)
    build_packet(@type_connect_ack, <<version::8>>)
  end

  @doc "Build a CONNECTION_PROBE packet"
  def connection_probe do
    build_packet(@type_connection_probe, <<>>)
  end

  @doc "Build a DATA keepalive packet (zero payload)"
  def data_keepalive do
    build_packet(@type_data, <<>>)
  end

  @doc "Build an Initial Setup packet (0x0A)"
  def initial_setup(params) do
    payload = <<
      @cmd_initial_setup::8,
      params.round_trip_time::32-big,
      params.max_socket_latency::32-big,
      params.min_socket_latency::32-big,
      params.sync_flag::8,
      params.async_data_bits::8,
      params.async_stop_bits::8,
      params.async_parity::8,
      params.async_data_mode::8
    >>

    build_packet(@type_data, payload)
  end

  @doc "Build a TX Setup packet (0x09)"
  def tx_setup(params) do
    payload = <<
      @cmd_tx_setup::8,
      params.data_rate::32-big,
      params.blocking_factor::32-big
    >>

    build_packet(@type_data, payload)
  end

  @doc "Build a TX Status packet (0x05)"
  def tx_status(params) do
    state_byte = encode_tx_state(params.state)

    payload = <<
      @cmd_transmit_status::8,
      state_byte::8,
      params.queued_bytes::32-big,
      params.free_bytes::32-big,
      params.serial_fifo_space::32-big
    >>

    build_packet(@type_data, payload)
  end

  @doc "Build a TX Data NACK packet (0x06)"
  def tx_nack(reason) do
    reason_byte = encode_nack_reason(reason)
    payload = <<@cmd_tx_data_nack::8, reason_byte::8>>
    build_packet(@type_data, payload)
  end

  @doc "Build a Carrier Detect packet (0x07)"
  def carrier_detect(params) do
    state_byte = encode_carrier_state(params.state)

    payload = <<
      @cmd_carrier_detect::8,
      state_byte::8,
      params.data_rate::32-big,
      params.blocking_factor::32-big
    >>

    build_packet(@type_data, payload)
  end

  @doc "Build an RX Data packet (0x02)"
  def rx_data(data, order) do
    order_byte = encode_order(order)

    payload = <<
      @cmd_rx_data::8,
      order_byte::8,
      data::binary
    >>

    build_packet(@type_data, payload)
  end

  @doc "Build an ERROR packet"
  def error_packet(code) do
    build_packet(@type_error, <<code::8>>)
  end

  @doc "Build a DATA packet with arbitrary payload"
  def data_packet(payload) when is_binary(payload) do
    build_packet(@type_data, payload)
  end

  @doc "Build a TX Data command payload (0x01)"
  def tx_data(data, order) do
    order_byte = encode_order(order)
    <<@cmd_tx_data::8, order_byte::8, data::binary>>
  end

  @doc "Build a Transmit ARM command payload (0x03)"
  def transmit_arm do
    <<@cmd_transmit_arm::8>>
  end

  @doc "Build a Transmit Start command payload (0x04)"
  def transmit_start do
    <<@cmd_transmit_start::8>>
  end

  @doc "Build a Request TX Status command payload (0x08)"
  def request_tx_status do
    <<@cmd_request_tx_status::8>>
  end

  @doc "Build an Abort TX command payload (0x0B)"
  def abort_tx do
    <<@cmd_abort_tx::8>>
  end

  @doc "Build an Abort RX command payload (0x0C)"
  def abort_rx do
    <<@cmd_abort_rx::8>>
  end

  @doc "Parse a payload command from a DATA packet"
  def parse_payload_command(<<@cmd_transmit_status::8, state::8, queued::32-big, free::32-big, _serial::32-big>>) do
    {:tx_status, decode_tx_state(state)}
  end

  def parse_payload_command(<<@cmd_tx_data_nack::8, reason::8>>) do
    {:tx_nack, decode_nack_reason(reason)}
  end

  def parse_payload_command(<<@cmd_rx_data::8, order::8, data::binary>>) do
    {:rx_data, data, decode_order(order)}
  end

  def parse_payload_command(<<@cmd_carrier_detect::8, state::8, rate::32-big, blocking::32-big>>) do
    case state do
      @carrier_detected ->
        {:carrier_detect, %{state: :detected, data_rate: rate, blocking_factor: blocking}}
      @carrier_no_carrier ->
        {:carrier_lost, %{}}
      _ ->
        {:carrier_detect, %{state: :unknown, data_rate: rate, blocking_factor: blocking}}
    end
  end

  def parse_payload_command(_), do: :unknown

  defp decode_tx_state(@tx_state_flushed), do: :flushed
  defp decode_tx_state(@tx_state_armed_port_not_ready), do: :armed_port_not_ready
  defp decode_tx_state(@tx_state_armed_port_ready), do: :armed
  defp decode_tx_state(@tx_state_started), do: :started
  defp decode_tx_state(@tx_state_draining_ok), do: :draining
  defp decode_tx_state(@tx_state_draining_forced), do: :draining_forced
  defp decode_tx_state(_), do: :unknown

  defp decode_nack_reason(0x01), do: :underrun
  defp decode_nack_reason(0x02), do: :not_armed
  defp decode_nack_reason(0x03), do: :queue_full
  defp decode_nack_reason(_), do: :unknown

  # ============================================================================
  # Packet Parsing
  # ============================================================================

  @doc """
  Parse a packet from a binary buffer.

  Returns:
  - `{:ok, packet, rest}` - Parsed packet and remaining buffer
  - `{:incomplete, buffer}` - Need more data
  - `{:error, reason}` - Parse error
  """
  def parse(<<@preamble, type::8, size::16-big, header_crc::16-big, rest::binary>> = buffer) do
    # Verify header CRC
    header_data = <<0x49, 0x50, 0x55, type, size::16-big>>

    if crc16(header_data) != header_crc do
      {:error, :header_crc_mismatch}
    else
      parse_payload(type, size, rest, buffer)
    end
  end

  def parse(buffer) when byte_size(buffer) < 8 do
    {:incomplete, buffer}
  end

  def parse(<<byte, rest::binary>>) do
    # Not at preamble - scan forward
    parse(rest)
  end

  def parse(<<>>) do
    {:incomplete, <<>>}
  end

  defp parse_payload(type, 0, rest, _buffer) do
    # No payload
    packet = decode_packet(type, <<>>)
    {:ok, packet, rest}
  end

  defp parse_payload(type, size, rest, buffer) do
    # Need size bytes + 2 byte CRC
    total_needed = size + 2

    if byte_size(rest) < total_needed do
      {:incomplete, buffer}
    else
      <<payload::binary-size(size), payload_crc::16-big, remaining::binary>> = rest

      if crc16(payload) != payload_crc do
        {:error, :payload_crc_mismatch}
      else
        packet = decode_packet(type, payload)
        {:ok, packet, remaining}
      end
    end
  end

  defp decode_packet(@type_connect, <<version::8>>) do
    {:connect, version}
  end

  defp decode_packet(@type_connect_ack, <<version::8>>) do
    {:connect_ack, version}
  end

  defp decode_packet(@type_connection_probe, <<>>) do
    :connection_probe
  end

  defp decode_packet(@type_data, <<>>) do
    :keepalive
  end

  defp decode_packet(@type_data, <<cmd::8, payload_rest::binary>>) do
    cmd_atom = decode_command(cmd)
    {:data, cmd_atom, payload_rest}
  end

  defp decode_packet(@type_error, <<code::8>>) do
    {:error_packet, code}
  end

  defp decode_packet(type, payload) do
    {:unknown, type, payload}
  end

  # ============================================================================
  # Encoding Helpers
  # ============================================================================

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

  defp encode_tx_state(:flushed), do: @tx_state_flushed
  defp encode_tx_state(:armed_port_not_ready), do: @tx_state_armed_port_not_ready
  defp encode_tx_state(:armed_port_ready), do: @tx_state_armed_port_ready
  defp encode_tx_state(:armed), do: @tx_state_armed_port_ready
  defp encode_tx_state(:ready_to_start), do: @tx_state_armed_port_ready  # Armed with data queued
  defp encode_tx_state(:starting), do: @tx_state_started
  defp encode_tx_state(:started), do: @tx_state_started
  defp encode_tx_state(:draining_ok), do: @tx_state_draining_ok
  defp encode_tx_state(:draining_forced), do: @tx_state_draining_forced
  defp encode_tx_state(_), do: @tx_state_flushed

  defp encode_carrier_state(:no_carrier), do: @carrier_no_carrier
  defp encode_carrier_state(:carrier_detected), do: @carrier_detected
  defp encode_carrier_state(:receiving), do: @carrier_detected
  defp encode_carrier_state(_), do: @carrier_no_carrier

  defp encode_nack_reason(:underrun), do: 0x01
  defp encode_nack_reason(:not_armed), do: 0x02
  defp encode_nack_reason(:queue_full), do: 0x03
  defp encode_nack_reason(_), do: 0xFF

  def encode_order(:first), do: @order_first
  def encode_order(:continuation), do: @order_continuation
  def encode_order(:last), do: @order_last
  def encode_order(:first_and_last), do: @order_first_and_last
  def encode_order(_), do: @order_continuation

  # ============================================================================
  # Decoding Helpers
  # ============================================================================

  defp decode_command(@cmd_tx_data), do: :tx_data
  defp decode_command(@cmd_rx_data), do: :rx_data
  defp decode_command(@cmd_transmit_arm), do: :transmit_arm
  defp decode_command(@cmd_transmit_start), do: :transmit_start
  defp decode_command(@cmd_transmit_status), do: :transmit_status
  defp decode_command(@cmd_tx_data_nack), do: :tx_data_nack
  defp decode_command(@cmd_carrier_detect), do: :carrier_detect
  defp decode_command(@cmd_request_tx_status), do: :request_tx_status
  defp decode_command(@cmd_tx_setup), do: :tx_setup
  defp decode_command(@cmd_initial_setup), do: :initial_setup
  defp decode_command(@cmd_abort_tx), do: :abort_tx
  defp decode_command(@cmd_abort_rx), do: :abort_rx
  defp decode_command(cmd), do: {:unknown, cmd}

  def decode_order(@order_first), do: :first
  def decode_order(@order_continuation), do: :continuation
  def decode_order(@order_last), do: :last
  def decode_order(@order_first_and_last), do: :first_and_last
  def decode_order(_), do: :continuation

  # ============================================================================
  # CRC-16 (per A.5.3)
  # ============================================================================

  @doc """
  Calculate CRC-16 per MIL-STD-188-110D Appendix A.5.3.

  Uses CRC-16-CCITT polynomial (0x1021) with initial value 0xFFFF.
  """
  def crc16(data) do
    crc16(data, 0xFFFF)
  end

  defp crc16(<<>>, crc), do: crc

  defp crc16(<<byte::8, rest::binary>>, crc) do
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
end
