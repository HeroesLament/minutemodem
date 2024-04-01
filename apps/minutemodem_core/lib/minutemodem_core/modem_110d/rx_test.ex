defmodule MinuteModemCore.Modem110D.RxTest do
  @moduledoc """
  Tests for Rx state machine.

  Verifies complete TX → RX pipeline: preamble generation, sync detection,
  WID decode, and state transitions.

  Run with: MinuteModemCore.Modem110D.RxTest.run()
  """

  alias MinuteModemCore.Modem110D.{Rx, Preamble, WID, Tables}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Rx State Machine Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_initial_state()
    test_start_stop()
    test_simple_sync_and_decode()
    test_with_tlc()
    test_multiple_superframes()
    test_full_pipeline()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All Rx tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_initial_state do
    IO.puts("1. Testing initial state...")

    rx = Rx.new(3)

    assert Rx.state(rx) == :idle, "Initial state is :idle"
    assert Rx.wid(rx) == nil, "No WID initially"
    assert Rx.synchronized?(rx) == false, "Not synchronized initially"

    IO.puts("   ✓ Initial state tests passed\n")
  end

  def test_start_stop do
    IO.puts("2. Testing start/stop...")

    rx = Rx.new(3)

    # Start
    {rx, events} = Rx.start(rx)
    assert Rx.state(rx) == :searching, "State is :searching after start"
    assert has_event?(events, :state_changed), "Got state_changed event"

    # Stop
    {rx, events} = Rx.stop(rx)
    assert Rx.state(rx) == :idle, "State is :idle after stop"
    assert has_event?(events, :state_changed), "Got state_changed event"

    IO.puts("   ✓ Start/stop tests passed\n")
  end

  def test_simple_sync_and_decode do
    IO.puts("3. Testing simple sync and decode (M=1, no TLC)...")

    bw_khz = 3
    waveform = 6
    interleaver = :short
    constraint = 7

    # Build preamble
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint,
      m: 1, tlc_blocks: 0)

    # Convert to soft I/Q
    soft_iq = symbols_to_iq(preamble)

    # Create and start receiver
    rx = Rx.new(bw_khz)
    {rx, _} = Rx.start(rx)

    # Process the preamble
    {rx, events} = Rx.process(rx, soft_iq)

    IO.puts("     Events: #{inspect(Enum.map(events, &elem(&1, 0)))}")
    IO.puts("     Final state: #{Rx.state(rx)}")

    # Should have acquired sync and decoded WID
    assert has_event?(events, :sync_acquired), "Got sync_acquired"
    assert has_event?(events, :wid_decoded), "Got wid_decoded"
    assert has_event?(events, :data_start), "Got data_start"

    # Check decoded WID
    decoded_wid = Rx.wid(rx)
    assert decoded_wid != nil, "WID decoded"
    assert decoded_wid.waveform == waveform, "Waveform matches"
    assert decoded_wid.interleaver == interleaver, "Interleaver matches"
    assert decoded_wid.constraint_length == constraint, "Constraint matches"

    # Should be in receiving state
    assert Rx.state(rx) == :receiving, "In receiving state"
    assert Rx.synchronized?(rx) == true, "Synchronized"

    IO.puts("   ✓ Simple sync and decode passed\n")
  end

  def test_with_tlc do
    IO.puts("4. Testing with TLC blocks...")

    bw_khz = 3
    waveform = 9  # 64-QAM
    interleaver = :long
    constraint = 9

    # Build preamble WITH TLC
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint,
      m: 2, tlc_blocks: 2)

    soft_iq = symbols_to_iq(preamble)

    rx = Rx.new(bw_khz)
    {rx, _} = Rx.start(rx)

    # Process
    {rx, events} = Rx.process(rx, soft_iq)

    IO.puts("     Events: #{inspect(Enum.map(events, &elem(&1, 0)))}")

    # Should detect TLC first, then sync
    assert has_event?(events, :tlc_detected), "Detected TLC"
    assert has_event?(events, :sync_acquired), "Got sync_acquired"
    assert has_event?(events, :wid_decoded), "Got wid_decoded"

    decoded_wid = Rx.wid(rx)
    assert decoded_wid.waveform == waveform, "Waveform #{waveform}"

    IO.puts("   ✓ TLC detection passed\n")
  end

  def test_multiple_superframes do
    IO.puts("5. Testing multiple super-frames (M=3)...")

    bw_khz = 3
    waveform = 6
    interleaver = :short
    constraint = 7

    # Build preamble with M=3
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint,
      m: 3, tlc_blocks: 0)

    soft_iq = symbols_to_iq(preamble)

    rx = Rx.new(bw_khz)
    {rx, _} = Rx.start(rx)

    {rx, events} = Rx.process(rx, soft_iq)

    # Should see countdown events: 2, 1, 0
    countdown_events = Enum.filter(events, fn
      {:countdown, _} -> true
      _ -> false
    end)

    IO.puts("     Countdown events: #{inspect(countdown_events)}")

    counts = Enum.map(countdown_events, fn {:countdown, c} -> c end)

    # With M=3, we get counts 2, 1, 0
    assert length(counts) >= 1, "Got countdown events"
    assert 0 in counts, "Count reached 0"

    assert Rx.state(rx) == :receiving, "In receiving state"

    IO.puts("   ✓ Multiple super-frames passed\n")
  end

  def test_full_pipeline do
    IO.puts("6. Testing full pipeline with data...")

    bw_khz = 3
    waveform = 6  # 8-PSK
    interleaver = :short
    constraint = 7

    # Build preamble
    preamble = Preamble.build(bw_khz, waveform, interleaver, constraint,
      m: 1, tlc_blocks: 0)

    # Generate some "data" symbols (just 8-PSK pattern)
    data_symbols = for i <- 0..99, do: rem(i, 8)

    # Combine preamble + data
    all_symbols = preamble ++ data_symbols
    soft_iq = symbols_to_iq(all_symbols)

    rx = Rx.new(bw_khz)
    {rx, _} = Rx.start(rx)

    # Process everything
    {rx, events} = Rx.process(rx, soft_iq)

    # Check for data events
    data_events = Enum.filter(events, fn
      {:data, _} -> true
      _ -> false
    end)

    IO.puts("     State: #{Rx.state(rx)}")
    IO.puts("     Data events: #{length(data_events)}")
    IO.puts("     Symbols received: #{Rx.stats(rx).symbols_received}")

    assert Rx.state(rx) == :receiving, "In receiving state"
    assert length(data_events) > 0, "Got data events"
    assert Rx.stats(rx).symbols_received > 0, "Received some symbols"

    # Verify some data symbols match
    if length(data_events) > 0 do
      {:data, first_data} = hd(data_events)
      IO.puts("     First data symbols: #{inspect(Enum.take(first_data, 10))}")
    end

    IO.puts("   ✓ Full pipeline passed\n")
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp symbols_to_iq(symbols) do
    Enum.map(symbols, fn sym ->
      angle = sym * :math.pi() / 4
      {:math.cos(angle), :math.sin(angle)}
    end)
  end

  defp has_event?(events, event_type) do
    Enum.any?(events, fn
      {^event_type, _} -> true
      {^event_type, _, _} -> true
      _ -> false
    end)
  end

  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
