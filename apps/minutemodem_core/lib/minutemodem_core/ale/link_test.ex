defmodule MinuteModemCore.ALE.LinkTest do
  @moduledoc """
  Shell test for ALE Link FSM with WALE waveforms.

  This simulates two rigs calling each other through the Link FSM,
  with manual PDU injection to simulate RX.

  Run with:
    MinuteModemCore.ALE.LinkTest.run()

  Or step-by-step:
    MinuteModemCore.ALE.LinkTest.setup()
    MinuteModemCore.ALE.LinkTest.test_call()
    MinuteModemCore.ALE.LinkTest.test_scan_and_receive()
    MinuteModemCore.ALE.LinkTest.cleanup()
  """

  alias MinuteModemCore.ALE.{Link, PDU, Waveform}

  @rig_a_id "test-rig-a"
  @rig_b_id "test-rig-b"
  @addr_a 0x1234
  @addr_b 0x5678

  def run do
    IO.puts("\n=== ALE Link FSM Test ===\n")

    setup()

    test_idle_state()
    test_scan_state()
    test_call_deep_wale()
    test_call_fast_wale()
    test_full_handshake()

    cleanup()

    IO.puts("\n=== All Link Tests Complete ===\n")
  end

  def setup do
    IO.puts("Setting up test rigs...")

    # Start Link FSMs for both rigs
    {:ok, _} = Link.start_link(rig_id: @rig_a_id, self_addr: @addr_a)
    {:ok, _} = Link.start_link(rig_id: @rig_b_id, self_addr: @addr_b)

    IO.puts("  Rig A: #{@rig_a_id} (0x#{Integer.to_string(@addr_a, 16)})")
    IO.puts("  Rig B: #{@rig_b_id} (0x#{Integer.to_string(@addr_b, 16)})")
    IO.puts("  ✓ Setup complete\n")
  end

  def cleanup do
    IO.puts("\nCleaning up...")
    GenStateMachine.stop(Link.via(@rig_a_id), :normal)
    GenStateMachine.stop(Link.via(@rig_b_id), :normal)
    IO.puts("  ✓ Cleanup complete")
  rescue
    _ -> IO.puts("  (already stopped)")
  end

  def test_idle_state do
    IO.puts("1. Testing idle state...")

    {:idle, nil} = Link.get_state(@rig_a_id)
    {:idle, nil} = Link.get_state(@rig_b_id)

    IO.puts("   ✓ Both rigs idle\n")
  end

  def test_scan_state do
    IO.puts("2. Testing scan state...")

    # Start scanning on Rig B
    :ok = Link.scan(@rig_b_id, waveform: :fast)

    {:scanning, %{waveform: :fast}} = Link.get_state(@rig_b_id)
    IO.puts("   Rig B scanning with Fast WALE")

    # Stop scanning
    Link.stop(@rig_b_id)
    Process.sleep(50)

    {:idle, nil} = Link.get_state(@rig_b_id)
    IO.puts("   ✓ Scan start/stop works\n")
  end

  def test_call_deep_wale do
    IO.puts("3. Testing Deep WALE call initiation...")

    # Rig A calls Rig B with Deep WALE
    :ok = Link.call(@rig_a_id, @addr_b, waveform: :deep, tuner_time_ms: 40)

    # Should go through LBT -> CALLING
    Process.sleep(250)  # Wait for LBT timeout

    case Link.get_state(@rig_a_id) do
      {:calling, addr} when addr == @addr_b ->
        IO.puts("   Rig A calling 0x#{Integer.to_string(addr, 16)} with Deep WALE")
        IO.puts("   ✓ Deep WALE call initiated")

      {:lbt, addr} ->
        IO.puts("   Rig A in LBT for 0x#{Integer.to_string(addr, 16)}")
        IO.puts("   ✓ Deep WALE call in progress")

      other ->
        IO.puts("   Unexpected state: #{inspect(other)}")
    end

    # Cancel the call
    Link.stop(@rig_a_id)
    Process.sleep(50)
    {:idle, nil} = Link.get_state(@rig_a_id)
    IO.puts("   ✓ Call cancelled\n")
  end

  def test_call_fast_wale do
    IO.puts("4. Testing Fast WALE call initiation...")

    # Rig A calls Rig B with Fast WALE
    :ok = Link.call(@rig_a_id, @addr_b, waveform: :fast, tuner_time_ms: 0)

    Process.sleep(250)

    case Link.get_state(@rig_a_id) do
      {:calling, addr} ->
        IO.puts("   Rig A calling 0x#{Integer.to_string(addr, 16)} with Fast WALE")
        IO.puts("   ✓ Fast WALE call initiated")

      other ->
        IO.puts("   State: #{inspect(other)}")
    end

    Link.stop(@rig_a_id)
    Process.sleep(50)
    IO.puts("   ✓ Call cancelled\n")
  end

  def test_full_handshake do
    IO.puts("5. Testing full handshake (simulated)...")

    # Put Rig B in scanning mode
    :ok = Link.scan(@rig_b_id, waveform: :fast)
    {:scanning, _} = Link.get_state(@rig_b_id)
    IO.puts("   Rig B scanning...")

    # Rig A initiates call
    :ok = Link.call(@rig_a_id, @addr_b, waveform: :fast)
    Process.sleep(250)

    {:calling, _} = Link.get_state(@rig_a_id)
    IO.puts("   Rig A calling...")

    # Simulate Rig B receiving the LSU_Req
    # (In real system, decoder would call Link.rx_pdu)
    lsu_req = %PDU.LsuReq{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      voice: false,
      more: false,
      equipment_class: 1,
      traffic_type: 0,
      assigned_subchannels: 0xFFFF,
      occupied_subchannels: 0
    }

    Link.rx_pdu(@rig_b_id, lsu_req)
    Process.sleep(50)

    case Link.get_state(@rig_b_id) do
      {:lbr, _} ->
        IO.puts("   Rig B in LBR (received call)")
      {:responding, _} ->
        IO.puts("   Rig B responding")
      {:linked, _} ->
        IO.puts("   Rig B linked!")
      other ->
        IO.puts("   Rig B state: #{inspect(other)}")
    end

    # Wait for Rig B to send confirm
    Process.sleep(300)

    case Link.get_state(@rig_b_id) do
      {:linked, info} ->
        IO.puts("   Rig B LINKED (we_are: #{info.we_are})")
      other ->
        IO.puts("   Rig B state: #{inspect(other)}")
    end

    # Simulate Rig A receiving LSU_Conf
    lsu_conf = %PDU.LsuConf{
      caller_addr: @addr_a,
      called_addr: @addr_b,
      voice: false,
      snr: 10,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }

    Link.rx_pdu(@rig_a_id, lsu_conf)
    Process.sleep(50)

    case Link.get_state(@rig_a_id) do
      {:linked, info} ->
        IO.puts("   Rig A LINKED (we_are: #{info.we_are})")
        IO.puts("   ✓ Full handshake complete!")
      other ->
        IO.puts("   Rig A state: #{inspect(other)}")
    end

    # Terminate the link
    IO.puts("   Terminating link...")
    Link.terminate_link(@rig_a_id, :normal)
    Process.sleep(100)

    {:idle, nil} = Link.get_state(@rig_a_id)
    IO.puts("   ✓ Link terminated\n")

    # Clean up Rig B
    Link.stop(@rig_b_id)
    Process.sleep(50)
  end

  # =========================================================================
  # Manual testing helpers
  # =========================================================================

  @doc """
  Show current state of both test rigs.
  """
  def status do
    IO.puts("\n--- Rig Status ---")

    try do
      state_a = Link.get_state(@rig_a_id)
      IO.puts("Rig A (0x#{Integer.to_string(@addr_a, 16)}): #{inspect(state_a)}")
    rescue
      _ -> IO.puts("Rig A: not running")
    end

    try do
      state_b = Link.get_state(@rig_b_id)
      IO.puts("Rig B (0x#{Integer.to_string(@addr_b, 16)}): #{inspect(state_b)}")
    rescue
      _ -> IO.puts("Rig B: not running")
    end

    IO.puts("")
  end

  @doc """
  Manually inject an LSU_Req to a rig (simulates receiving a call).
  """
  def inject_call(rig_id, from_addr, to_addr) do
    pdu = %PDU.LsuReq{
      caller_addr: from_addr,
      called_addr: to_addr,
      voice: false,
      more: false,
      equipment_class: 1,
      traffic_type: 0,
      assigned_subchannels: 0xFFFF,
      occupied_subchannels: 0
    }

    Link.rx_pdu(rig_id, pdu)
    IO.puts("Injected LSU_Req: #{Integer.to_string(from_addr, 16)} -> #{Integer.to_string(to_addr, 16)}")
  end

  @doc """
  Manually inject an LSU_Conf to a rig (simulates receiving confirmation).
  """
  def inject_confirm(rig_id, caller_addr, called_addr) do
    pdu = %PDU.LsuConf{
      caller_addr: caller_addr,
      called_addr: called_addr,
      voice: false,
      snr: 10,
      tx_subchannels: 0xFFFF,
      rx_subchannels: 0xFFFF
    }

    Link.rx_pdu(rig_id, pdu)
    IO.puts("Injected LSU_Conf: #{Integer.to_string(caller_addr, 16)} <-> #{Integer.to_string(called_addr, 16)}")
  end

  @doc """
  Generate WALE frame symbols for a PDU (for testing modulator).
  """
  def generate_frame(pdu_type, opts \\ []) do
    waveform = Keyword.get(opts, :waveform, :fast)

    pdu = case pdu_type do
      :lsu_req ->
        %PDU.LsuReq{
          caller_addr: Keyword.get(opts, :caller, @addr_a),
          called_addr: Keyword.get(opts, :called, @addr_b),
          voice: false
        }

      :lsu_conf ->
        %PDU.LsuConf{
          caller_addr: Keyword.get(opts, :caller, @addr_a),
          called_addr: Keyword.get(opts, :called, @addr_b),
          voice: false,
          snr: 10
        }
    end

    pdu_binary = PDU.encode(pdu)

    symbols = Waveform.assemble_frame(pdu_binary,
      waveform: waveform,
      async: true,
      tuner_time_ms: Keyword.get(opts, :tuner_time_ms, 0)
    )

    timing = Waveform.frame_timing(pdu_binary, waveform: waveform)

    IO.puts("Generated #{waveform} frame:")
    IO.puts("  PDU: #{pdu_type}")
    IO.puts("  Symbols: #{length(symbols)}")
    IO.puts("  Duration: #{Float.round(timing.duration_ms, 1)}ms")

    symbols
  end
end
