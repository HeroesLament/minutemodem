defmodule MinuteModemCore.Interface.KISS do
  @moduledoc """
  KISS TNC interface adapter.

  Implements the KISS (Keep It Simple Stupid) protocol for amateur radio
  TNC compatibility. Much simpler than MIL-STD-188-110D - just frames
  with minimal control.

  ## KISS Framing

      FEND (0xC0) | Command | Data... | FEND (0xC0)

  - FEND (0xC0) delimits frames
  - Escaped: 0xC0 → 0xDB 0xDC, 0xDB → 0xDB 0xDD
  - Command byte: port (high nibble) + command (low nibble)

  ## Commands

      0x00 - Data frame (port 0)
      0x01 - TX delay
      0x02 - Persistence
      0x03 - Slot time
      0x04 - TX tail
      0x05 - Full duplex
      0xFF - Return (exit KISS mode)

  ## Modem Mapping

  KISS is stateless from the TNC perspective. We map to the Modem API:
  - Each received KISS data frame → auto-arm, auto-start, tx_data with :first_and_last
  - Modem RX data → KISS data frame out
  - KISS has no explicit ARM/START - we handle it implicitly

  ## Transports

  - TCP (common for software TNCs like Dire Wolf)
  - Serial (traditional hardware TNCs)
  """

  use GenServer
  import Bitwise

  require Logger

  alias MinuteModemCore.Modem

  @fend 0xC0
  @fesc 0xDB
  @tfend 0xDC
  @tfesc 0xDD

  defstruct [
    :rig_id,
    :transport,      # :tcp | :serial
    :socket,         # TCP socket or serial port
    :recv_buffer,
    :tx_delay,       # ms
    :persistence,    # 0-255
    :slot_time       # ms
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {MinuteModemCore.Interface.Registry, {rig_id, :kiss}}}
  end

  def child_spec(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    %{
      id: {__MODULE__, rig_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    port = Keyword.get(opts, :port, 8001)

    # For now, only TCP KISS
    listen_opts = [:binary, packet: :raw, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen_socket} ->
        Logger.info("[KISS] Listening on port #{port} for rig #{rig_id}")

        state = %__MODULE__{
          rig_id: rig_id,
          transport: :tcp,
          socket: nil,
          recv_buffer: <<>>,
          tx_delay: 50,
          persistence: 63,
          slot_time: 10
        }

        # Subscribe to modem RX events
        Modem.subscribe(rig_id, filter: :rx)

        # Start accepting
        send(self(), {:accept, listen_socket})

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:accept, listen_socket}, state) do
    # Simple blocking accept - for production, use Task or ranch
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, socket} ->
        Logger.info("[KISS] Client connected")
        :inet.setopts(socket, [active: true])
        {:noreply, %{state | socket: socket}}

      {:error, :timeout} ->
        send(self(), {:accept, listen_socket})
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[KISS] Accept error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    state = %{state | recv_buffer: state.recv_buffer <> data}

    case process_kiss_frames(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[KISS] Frame error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("[KISS] Client disconnected")
    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:modem, {:rx_data, payload, _order}}, state) do
    # Send RX data as KISS frame
    if state.socket do
      frame = encode_kiss_frame(0x00, payload)
      :gen_tcp.send(state.socket, frame)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:modem, _event}, state) do
    # Ignore other modem events
    {:noreply, state}
  end

  # ============================================================================
  # KISS Frame Processing
  # ============================================================================

  defp process_kiss_frames(state) do
    case extract_frame(state.recv_buffer) do
      {:ok, frame, rest} ->
        state = %{state | recv_buffer: rest}

        case handle_kiss_frame(frame, state) do
          {:ok, new_state} ->
            process_kiss_frames(new_state)

          {:error, _} = err ->
            err
        end

      :incomplete ->
        {:ok, state}
    end
  end

  defp extract_frame(buffer) do
    # Find FEND...FEND
    case :binary.split(buffer, <<@fend>>) do
      [_before, rest] ->
        case :binary.split(rest, <<@fend>>) do
          [frame_data, remaining] ->
            {:ok, unescape(frame_data), remaining}

          [_incomplete] ->
            :incomplete
        end

      [_no_fend] ->
        :incomplete
    end
  end

  defp handle_kiss_frame(<<>>, state) do
    # Empty frame, ignore
    {:ok, state}
  end

  defp handle_kiss_frame(<<cmd::8, data::binary>>, state) do
    port = bsr(cmd, 4)
    command = band(cmd, 0x0F)

    case {port, command} do
      {0, 0x00} ->
        # Data frame - send to modem
        handle_tx_data(data, state)

      {_, 0x01} ->
        # TX delay
        <<delay::8, _::binary>> = data
        {:ok, %{state | tx_delay: delay * 10}}

      {_, 0x02} ->
        # Persistence
        <<p::8, _::binary>> = data
        {:ok, %{state | persistence: p}}

      {_, 0x03} ->
        # Slot time
        <<slot::8, _::binary>> = data
        {:ok, %{state | slot_time: slot * 10}}

      {_, 0xFF} ->
        # Return - exit KISS mode (ignore for TCP)
        {:ok, state}

      _ ->
        Logger.debug("[KISS] Unknown command: port=#{port} cmd=#{command}")
        {:ok, state}
    end
  end

  defp handle_tx_data(data, state) do
    # KISS is fire-and-forget. We auto-arm, send as single frame, auto-start.
    rig_id = state.rig_id

    with {:ok, _} <- Modem.arm_tx(rig_id),
         :ok <- Modem.tx_data(rig_id, data, order: :first_and_last),
         {:ok, _} <- Modem.start_tx(rig_id) do
      {:ok, state}
    else
      {:error, reason} ->
        Logger.warning("[KISS] TX failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # ============================================================================
  # KISS Encoding
  # ============================================================================

  defp encode_kiss_frame(command, data) do
    escaped = escape(data)
    <<@fend, command::8, escaped::binary, @fend>>
  end

  defp escape(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn
      @fend -> [@fesc, @tfend]
      @fesc -> [@fesc, @tfesc]
      byte -> [byte]
    end)
    |> :binary.list_to_bin()
  end

  defp unescape(data) do
    unescape(data, <<>>)
  end

  defp unescape(<<>>, acc), do: acc
  defp unescape(<<@fesc, @tfend, rest::binary>>, acc), do: unescape(rest, acc <> <<@fend>>)
  defp unescape(<<@fesc, @tfesc, rest::binary>>, acc), do: unescape(rest, acc <> <<@fesc>>)
  defp unescape(<<byte::8, rest::binary>>, acc), do: unescape(rest, acc <> <<byte>>)
end
