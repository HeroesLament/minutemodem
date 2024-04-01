defmodule MinuteModemClient.Scenes.DTE do
  @moduledoc """
  DTE Test scene - reactive interface for MIL-STD-188-110D Appendix A.

  All UI state is derived from client notifications:
  - `client_state` - Connection FSM state (from client)
  - `tx_state` - Modem TX state (from modem via client)
  - `carrier` - RX carrier state (from modem via client)

  UI elements enable/disable based on derived predicates.
  """

  use WxMVU.Scene

  alias MinuteModemClient.DTE.Client

  @canned_messages [
    {"MSG 1", "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG"},
    {"MSG 2", "HELLO FROM MINUTEMODEM - TEST MESSAGE"},
    {"MSG 3", "REQUEST STATUS REPORT"},
    {"MSG 4", "ACKNOWLEDGE - MESSAGE RECEIVED"}
  ]

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    %{
      # Connection config
      host: "127.0.0.1",
      port: "3000",

      # Client process
      client_pid: nil,

      # Reactive state (updated by client notifications)
      client_state: :disconnected,
      tx_state: :flushed,
      carrier: :lost,
      last_error: nil,

      # ARQ state
      arq_enabled: true,
      tx_seq: 0,
      rx_seq: 0,
      pending_ack: nil,
      max_retries: 3,

      # Logs
      tx_log: [],
      rx_log: []
    }
  end

  ## ------------------------------------------------------------------
  ## Derived State (for UI)
  ## ------------------------------------------------------------------

  defp connected?(model), do: model.client_state == :operational
  defp connecting?(model), do: model.client_state in [:connecting, :connect_received, :waiting_probe, :receiving_setup]
  defp can_arm?(model), do: connected?(model) and model.tx_state == :flushed
  defp armed?(model), do: model.tx_state in [:armed, :armed_port_not_ready]
  defp can_start?(model), do: connected?(model) and armed?(model)
  defp transmitting?(model), do: model.tx_state in [:started, :draining, :draining_forced]
  defp can_send_data?(model) do
    connected?(model) and model.tx_state in [:armed, :started] and
      # Don't allow new ARQ data while waiting for ACK on previous frame
      (not model.arq_enabled or model.pending_ack == nil)
  end
  defp can_abort?(model), do: connected?(model) and model.tx_state != :flushed

  defp status_text(model) do
    cond do
      model.last_error -> "Error: #{inspect(model.last_error)}"
      model.client_state == :disconnected -> "Disconnected"
      model.client_state == :connecting -> "Connecting..."
      model.client_state == :connect_received -> "Handshaking..."
      model.client_state == :waiting_probe -> "Waiting for probe..."
      model.client_state == :receiving_setup -> "Receiving setup..."
      transmitting?(model) -> "Transmitting (#{model.tx_state})"
      armed?(model) -> "Armed - ready to transmit"
      connected?(model) -> "Connected (TX: #{model.tx_state})"
      true -> "Unknown"
    end
  end

  ## ------------------------------------------------------------------
  ## Handle Info - Route client messages to handle_event
  ## ------------------------------------------------------------------

  def handle_info({:dte_client_state, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_tx_state, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_carrier, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_rx_data, _, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_rx_complete}, model), do: {:noreply, model}
  def handle_info({:dte_tx_nack, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_error, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:dte_disconnected, _} = msg, model), do: {:noreply, handle_event(msg, model)}
  def handle_info({:arq_timeout, _} = msg, model), do: {:noreply, handle_event(msg, model)}

  ## ------------------------------------------------------------------
  ## Handle Event - Client State Notifications
  ## ------------------------------------------------------------------

  def handle_event({:dte_client_state, state}, model) do
    %{model | client_state: state, last_error: nil}
  end

  def handle_event({:dte_tx_state, state}, model) do
    tx_entry = "#{timestamp()} TX State: #{state}"
    tx_log = prepend_log(model.tx_log, tx_entry)

    # Drive TX LED based on state
    case state do
      s when s in [:started, :draining, :draining_forced] ->
        WxMVU.GLCanvas.send_data(:tx_led, :on)
      :armed ->
        WxMVU.GLCanvas.send_data(:tx_led, {:blink, 500})
      _ ->
        WxMVU.GLCanvas.send_data(:tx_led, :off)
    end

    # Start ARQ timer when transmission actually begins
    model = if state == :started and model.arq_enabled do
      case model.pending_ack do
        {seq, _frame, _retries} ->
          schedule_arq_timeout(seq)
          model
        _ ->
          model
      end
    else
      model
    end

    %{model | tx_state: state, tx_log: tx_log}
  end

  def handle_event({:dte_carrier, state}, model) do
    rx_entry = "#{timestamp()} Carrier: #{state}"
    rx_log = prepend_log(model.rx_log, rx_entry)

    # Drive RX LED based on carrier
    case state do
      :acquired -> WxMVU.GLCanvas.send_data(:rx_led, :on)
      :lost -> WxMVU.GLCanvas.send_data(:rx_led, :off)
    end

    %{model | carrier: state, rx_log: rx_log}
  end

  def handle_event({:dte_rx_data, parsed, order}, model) do
    # Handle structured data from client: %{type: :data|:ack|:raw, seq: integer, data: binary}
    rx_entry = case parsed do
      %{type: :ack, seq: seq} ->
        "#{timestamp()} [#{seq}] ACK (#{order})"
      %{type: :data, seq: seq, data: data} ->
        "#{timestamp()} [#{seq}] #{format_payload(data)} (#{order})"
      %{type: :raw, data: data} ->
        "#{timestamp()} [-] #{format_payload(data)} (#{order})"
      # Legacy binary format fallback
      payload when is_binary(payload) ->
        {seq, data} = if model.arq_enabled do
          parse_arq_frame(payload)
        else
          {nil, payload}
        end
        "#{timestamp()} [#{seq || "-"}] #{format_payload(data)} (#{order})"
    end

    rx_log = prepend_log(model.rx_log, rx_entry)

    # Handle ARQ logic
    model = case parsed do
      # Received ACK - clear pending_ack if sequence matches
      %{type: :ack, seq: seq} when model.arq_enabled ->
        case model.pending_ack do
          {^seq, _, _} ->
            tx_entry = "#{timestamp()} [#{seq}] ACK confirmed"
            tx_log = prepend_log(model.tx_log, tx_entry)
            %{model | pending_ack: nil, tx_log: tx_log}
          _ ->
            model  # ACK for wrong seq, ignore
        end

      # Received data - send ACK back
      %{type: :data, seq: seq, data: _data} when model.arq_enabled ->
        handle_rx_arq(model, seq, :data_frame)

      _ ->
        model
    end

    %{model | rx_log: rx_log}
  end

  def handle_event({:dte_tx_nack, reason}, model) do
    tx_entry = "#{timestamp()} NACK: #{reason}"
    tx_log = prepend_log(model.tx_log, tx_entry)
    # Clear pending_ack - transmission failed, nothing to wait for
    %{model | tx_log: tx_log, last_error: {:nack, reason}, pending_ack: nil}
  end

  def handle_event({:dte_error, reason}, model) do
    %{model | last_error: reason}
  end

  def handle_event({:dte_disconnected, reason}, model) do
    # Turn off LEDs
    WxMVU.GLCanvas.send_data(:tx_led, :off)
    WxMVU.GLCanvas.send_data(:rx_led, :off)

    %{model |
      client_state: :disconnected,
      client_pid: nil,
      tx_state: :flushed,
      carrier: :lost,
      last_error: if(reason != :user_request, do: reason, else: nil),
      pending_ack: nil
    }
  end

  ## ------------------------------------------------------------------
  ## Handle Event - UI Actions
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :dte_host, :change, value}, model) do
    IO.puts("[DTE] HOST CHANGE: #{inspect(model.host)} -> #{inspect(value)}")
    %{model | host: value}
  end

  def handle_event({:ui_event, :dte_port, :change, value}, model) do
    IO.puts("[DTE] PORT CHANGE: #{inspect(model.port)} -> #{inspect(value)}")
    %{model | port: value}
  end

  def handle_event({:ui_event, :dte_connect, :click}, model) do
    IO.puts("[DTE] CONNECT clicked, host=#{inspect(model.host)}, port=#{inspect(model.port)}")
    if connected?(model) or connecting?(model) do
      # Disconnect
      if model.client_pid, do: Client.disconnect(model.client_pid)
      %{model | client_state: :disconnected, client_pid: nil, tx_state: :flushed}
    else
      # Connect
      port = String.to_integer(model.port)
      case Client.connect(model.host, port, self()) do
        {:ok, pid} ->
          %{model | client_pid: pid, last_error: nil}
        {:error, reason} ->
          %{model | last_error: {:connect_failed, reason}}
      end
    end
  end

  def handle_event({:ui_event, :dte_arq, :click}, model) do
    %{model | arq_enabled: not model.arq_enabled}
  end

  def handle_event({:ui_event, :dte_arm, :click}, model) do
    if can_arm?(model) and model.client_pid do
      Client.arm(model.client_pid)
    end
    model
  end

  def handle_event({:ui_event, :dte_start, :click}, model) do
    if can_start?(model) and model.client_pid do
      Client.start_tx(model.client_pid)
    end
    model
  end

  def handle_event({:ui_event, :dte_abort, :click}, model) do
    if can_abort?(model) and model.client_pid do
      Client.abort(model.client_pid)
    end
    model
  end

  # Canned messages
  def handle_event({:ui_event, :dte_msg1, :click}, model), do: send_canned(model, 0)
  def handle_event({:ui_event, :dte_msg2, :click}, model), do: send_canned(model, 1)
  def handle_event({:ui_event, :dte_msg3, :click}, model), do: send_canned(model, 2)
  def handle_event({:ui_event, :dte_msg4, :click}, model), do: send_canned(model, 3)

  # ARQ timeout
  def handle_event({:arq_timeout, seq}, model) do
    case model.pending_ack do
      {^seq, data, retries} when retries < model.max_retries ->
        # Retransmit - timer will be re-scheduled when tx_state becomes :started
        if model.client_pid do
          Client.send_data(model.client_pid, data, :first_and_last)
          Client.start_tx(model.client_pid)
        end
        tx_entry = "#{timestamp()} [#{seq}] RETRY #{retries + 1}"
        tx_log = prepend_log(model.tx_log, tx_entry)
        %{model | pending_ack: {seq, data, retries + 1}, tx_log: tx_log}

      {^seq, _data, _retries} ->
        tx_entry = "#{timestamp()} [#{seq}] FAILED - max retries"
        tx_log = prepend_log(model.tx_log, tx_entry)
        %{model | pending_ack: nil, tx_log: tx_log, last_error: :arq_failed}

      _ ->
        model
    end
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    [
      {:ensure_panel, :dte_root, {:page, :dte}, []}
    ] ++
      connection_controls(model) ++
      modem_controls(model) ++
      message_buttons(model) ++
      status_display(model) ++
      led_indicators(model) ++
      log_display(model) ++
      [
        {:layout, :dte_root,
         {:vbox, [padding: 10],
          [
            {:hbox, [],
             [:dte_host_label, :dte_host, {:spacer, 5},
              :dte_port_label, :dte_port, {:spacer, 10},
              :dte_connect, {:spacer, 20}, :dte_arq]},
            {:spacer, 15},
            {:hbox, [], [
              :dte_arm, {:spacer, 10},
              :dte_start, {:spacer, 10},
              :dte_abort,
              {:spacer, 20},
              :tx_led, {:spacer, 5}, :rx_led
            ]},
            {:spacer, 15},
            {:hbox, [], [:dte_msg1, {:spacer, 5}, :dte_msg2, {:spacer, 5},
                         :dte_msg3, {:spacer, 5}, :dte_msg4]},
            {:spacer, 15},
            {:hbox, [], [:dte_status_label, :dte_status]},
            {:spacer, 5},
            {:hbox, [], [:dte_tx_state_label, :dte_tx_state, {:spacer, 20},
                         :dte_carrier_label, :dte_carrier]},
            {:spacer, 10},
            {:hbox, [proportion: 1, flag: :expand],
             [{:vbox, [proportion: 1, flag: :expand],
               [:dte_tx_label, {:dte_tx_log, proportion: 1, flag: :expand}]},
              {:spacer, 10},
              {:vbox, [proportion: 1, flag: :expand],
               [:dte_rx_label, {:dte_rx_log, proportion: 1, flag: :expand}]}]}
          ]}}
      ]
  end

  defp connection_controls(model) do
    connect_label = cond do
      connected?(model) -> "Disconnect"
      connecting?(model) -> "Cancel"
      true -> "Connect"
    end

    arq_label = if model.arq_enabled, do: "ARQ: ON", else: "ARQ: OFF"

    [
      {:ensure_widget, :dte_host_label, :static_text, :dte_root, label: "Host:"},
      {:ensure_widget, :dte_host, :text_ctrl, :dte_root, value: model.host, size: {120, -1}},
      {:set, :dte_host, enabled: not connecting?(model) and not connected?(model)},
      {:ensure_widget, :dte_port_label, :static_text, :dte_root, label: "Port:"},
      {:ensure_widget, :dte_port, :text_ctrl, :dte_root, value: model.port, size: {60, -1}},
      {:set, :dte_port, enabled: not connecting?(model) and not connected?(model)},
      {:ensure_widget, :dte_connect, :button, :dte_root, label: connect_label, size: {100, -1}},
      {:set, :dte_connect, label: connect_label},
      {:ensure_widget, :dte_arq, :button, :dte_root, label: arq_label, size: {80, -1}},
      {:set, :dte_arq, label: arq_label}
    ]
  end

  defp modem_controls(model) do
    arm_label = if armed?(model), do: "ARMED ✓", else: "ARM"
    start_label = if transmitting?(model), do: "TX...", else: "START"

    [
      {:ensure_widget, :dte_arm, :button, :dte_root, label: arm_label, size: {80, 40}},
      {:set, :dte_arm, label: arm_label},
      {:set, :dte_arm, enabled: can_arm?(model)},
      {:ensure_widget, :dte_start, :button, :dte_root, label: start_label, size: {80, 40}},
      {:set, :dte_start, label: start_label},
      {:set, :dte_start, enabled: can_start?(model)},
      {:ensure_widget, :dte_abort, :button, :dte_root, label: "ABORT", size: {80, 40}},
      {:set, :dte_abort, enabled: can_abort?(model)}
    ]
  end

  defp message_buttons(model) do
    enabled = can_send_data?(model)

    Enum.with_index(@canned_messages)
    |> Enum.flat_map(fn {{label, _msg}, idx} ->
      widget_id = String.to_atom("dte_msg#{idx + 1}")
      [
        {:ensure_widget, widget_id, :button, :dte_root, label: label, size: {100, 50}},
        {:set, widget_id, enabled: enabled}
      ]
    end)
  end

  defp status_display(model) do
    status = status_text(model)
    tx_state_str = Atom.to_string(model.tx_state)
    carrier_str = Atom.to_string(model.carrier)

    [
      {:ensure_widget, :dte_status_label, :static_text, :dte_root, label: "Status:"},
      {:ensure_widget, :dte_status, :static_text, :dte_root, label: status},
      {:set, :dte_status, label: status},
      {:ensure_widget, :dte_tx_state_label, :static_text, :dte_root, label: "TX:"},
      {:ensure_widget, :dte_tx_state, :static_text, :dte_root, label: tx_state_str},
      {:set, :dte_tx_state, label: tx_state_str},
      {:ensure_widget, :dte_carrier_label, :static_text, :dte_root, label: "Carrier:"},
      {:ensure_widget, :dte_carrier, :static_text, :dte_root, label: carrier_str},
      {:set, :dte_carrier, label: carrier_str}
    ]
  end

  defp led_indicators(_model) do
    [
      {:ensure_gl_canvas, :tx_led, :dte_root,
        module: MinuteModemClient.Canvas.LED,
        size: {20, 20},
        opts: [color: :green, initial: :off]},

      {:ensure_gl_canvas, :rx_led, :dte_root,
        module: MinuteModemClient.Canvas.LED,
        size: {20, 20},
        opts: [color: :yellow, initial: :off]}
    ]
  end

  defp log_display(model) do
    tx_text = Enum.join(model.tx_log, "\n")
    rx_text = Enum.join(model.rx_log, "\n")

    [
      {:ensure_widget, :dte_tx_label, :static_text, :dte_root, label: "TX Log:"},
      {:ensure_widget, :dte_tx_log, :text_ctrl, :dte_root,
       style: [:te_multiline, :te_readonly], value: tx_text, size: {300, 150}},
      {:set, :dte_tx_log, value: tx_text},
      {:ensure_widget, :dte_rx_label, :static_text, :dte_root, label: "RX Log:"},
      {:ensure_widget, :dte_rx_log, :text_ctrl, :dte_root,
       style: [:te_multiline, :te_readonly], value: rx_text, size: {300, 150}},
      {:set, :dte_rx_log, value: rx_text}
    ]
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp send_canned(model, index) do
    if not can_send_data?(model) or is_nil(model.client_pid) do
      model
    else
      {_label, message} = Enum.at(@canned_messages, index)

      {data, model} = if model.arq_enabled do
        seq = model.tx_seq
        frame = build_arq_frame(seq, :data, message)
        # DON'T start timer here - wait until tx_state becomes :started
        {frame, %{model | tx_seq: rem(seq + 1, 256), pending_ack: {seq, frame, 0}}}
      else
        {message, model}
      end

      Client.send_data(model.client_pid, data, :first_and_last)

      seq_str = if model.arq_enabled, do: "[#{model.tx_seq - 1}] ", else: ""
      tx_entry = "#{timestamp()} #{seq_str}#{String.slice(message, 0, 30)}..."
      tx_log = prepend_log(model.tx_log, tx_entry)

      %{model | tx_log: tx_log}
    end
  end

  defp handle_rx_arq(model, seq, :data_frame) do
    # Data frame received - send ACK back
    model = if model.client_pid do
      ack = build_arq_frame(seq, :ack, <<>>)
      Client.send_data(model.client_pid, ack, :first_and_last)
      Client.start_tx(model.client_pid)
      tx_entry = "#{timestamp()} [#{seq}] ACK sent"
      tx_log = prepend_log(model.tx_log, tx_entry)
      %{model | tx_log: tx_log}
    else
      model
    end
    %{model | rx_seq: rem(seq + 1, 256)}
  end

  defp build_arq_frame(seq, :data, payload), do: <<0x00, seq::8, payload::binary>>
  # Pad ACK to 48 bytes to fill one interleaver block (per MIL-STD-188-110D D.5.4.3)
  # Short interleaver input data block is ~45 bytes; padding ensures decoder gets enough symbols
  defp build_arq_frame(seq, :ack, _payload), do: <<0x01, seq::8, 0::368>>

  defp parse_arq_frame(<<0x00, seq::8, payload::binary>>), do: {seq, payload}
  # ACK is padded to 48 bytes - match type byte and seq, ignore padding
  defp parse_arq_frame(<<0x01, seq::8, _padding::binary>>), do: {seq, :ack}
  defp parse_arq_frame(data), do: {nil, data}

  defp schedule_arq_timeout(seq) do
    Process.send_after(self(), {:arq_timeout, seq}, 5000)
  end

  defp prepend_log(log, entry) do
    Enum.take([entry | log], 50)
  end

  defp timestamp do
    {_, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()
  end

  defp format_payload(:ack), do: "ACK"
  defp format_payload(data) when is_binary(data) and byte_size(data) > 40 do
    "#{String.slice(data, 0, 40)}... (#{byte_size(data)} bytes)"
  end
  defp format_payload(data) when is_binary(data), do: data
  defp format_payload(other), do: inspect(other)
end
