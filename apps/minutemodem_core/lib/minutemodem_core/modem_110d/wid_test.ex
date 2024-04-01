defmodule MinuteModemCore.Modem110D.WIDTest do
  @moduledoc """
  Tests for WID and Downcount structs.

  Run with: MinuteModemCore.Modem110D.WIDTest.run()
  """

  alias MinuteModemCore.Modem110D.{WID, Downcount, Tables}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("WID and Downcount Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    test_wid_roundtrip()
    test_wid_decode()
    test_wid_properties()
    test_wid_checksum_validation()
    test_downcount_roundtrip()
    test_downcount_parity_validation()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("All WID/Downcount tests passed!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def test_wid_roundtrip do
    IO.puts("1. Testing WID encode/decode roundtrip...")

    # Test all valid waveforms
    for wf <- 0..13,
        ilv <- [:ultra_short, :short, :medium, :long],
        k <- [7, 9] do
      wid = WID.new(wf, ilv, k)
      dibits = WID.encode(wid)

      assert length(dibits) == 5, "WID encode produces 5 di-bits"
      assert Enum.all?(dibits, &(&1 in 0..3)), "All di-bits in range 0-3"

      {:ok, decoded} = WID.decode(dibits)

      assert decoded.waveform == wf, "Waveform roundtrip: #{wf}"
      assert decoded.interleaver == ilv, "Interleaver roundtrip: #{ilv}"
      assert decoded.constraint_length == k, "Constraint length roundtrip: #{k}"
    end

    IO.puts("   ✓ WID roundtrip tests passed (#{14 * 4 * 2} combinations)\n")
  end

  def test_wid_decode do
    IO.puts("2. Testing WID decode specifics...")

    # Waveform 6 (8-PSK), short interleaver, K=7
    wid = WID.new(6, :short, 7)
    dibits = WID.encode(wid)
    {:ok, decoded} = WID.decode(dibits)

    assert decoded.waveform == 6, "Waveform 6"
    assert decoded.interleaver == :short, "Short interleaver"
    assert decoded.constraint_length == 7, "K=7"

    # Waveform 9 (64-QAM), long interleaver, K=9
    wid2 = WID.new(9, :long, 9)
    dibits2 = WID.encode(wid2)
    {:ok, decoded2} = WID.decode(dibits2)

    assert decoded2.waveform == 9, "Waveform 9"
    assert decoded2.interleaver == :long, "Long interleaver"
    assert decoded2.constraint_length == 9, "K=9"

    IO.puts("   ✓ WID decode tests passed\n")
  end

  def test_wid_properties do
    IO.puts("3. Testing WID derived properties...")

    # BPSK waveform
    bpsk_wid = WID.new(1, :short, 7)
    assert WID.constellation(bpsk_wid) == :bpsk, "WF1 is BPSK"
    assert WID.bits_per_symbol(bpsk_wid) == 1, "BPSK is 1 bit/sym"
    assert WID.psk?(bpsk_wid) == true, "BPSK is PSK"
    assert WID.qam?(bpsk_wid) == false, "BPSK is not QAM"

    # 8-PSK waveform
    psk8_wid = WID.new(6, :medium, 7)
    assert WID.constellation(psk8_wid) == :psk8, "WF6 is 8-PSK"
    assert WID.bits_per_symbol(psk8_wid) == 3, "8-PSK is 3 bits/sym"
    assert WID.psk?(psk8_wid) == true, "8-PSK is PSK"

    # 64-QAM waveform
    qam_wid = WID.new(9, :long, 9)
    assert WID.constellation(qam_wid) == :qam64, "WF9 is 64-QAM"
    assert WID.bits_per_symbol(qam_wid) == 6, "64-QAM is 6 bits/sym"
    assert WID.psk?(qam_wid) == false, "64-QAM is not PSK"
    assert WID.qam?(qam_wid) == true, "64-QAM is QAM"

    # Walsh waveform
    walsh_wid = WID.new(0, :ultra_short, 7)
    assert WID.walsh?(walsh_wid) == true, "WF0 is Walsh"
    assert WID.walsh?(psk8_wid) == false, "WF6 is not Walsh"

    # Frame params
    params = WID.frame_params(psk8_wid, 3)
    assert params.data_symbols == 256, "WF6 at 3kHz has U=256"
    assert params.probe_symbols == 32, "WF6 at 3kHz has K=32"

    IO.puts("   ✓ WID property tests passed\n")
  end

  def test_wid_checksum_validation do
    IO.puts("4. Testing WID checksum validation...")

    # Valid WID
    wid = WID.new(6, :short, 7)
    dibits = WID.encode(wid)
    assert match?({:ok, _}, WID.decode(dibits)), "Valid WID decodes"

    # Corrupt one di-bit
    [w4, w3, w2, w1, w0] = dibits
    corrupted = [w4, w3, w2, w1, rem(w0 + 1, 4)]
    assert match?({:error, :checksum_mismatch}, WID.decode(corrupted)), "Corrupted WID fails checksum"

    # Invalid input
    assert match?({:error, :invalid_input}, WID.decode([1, 2, 3])), "Wrong length fails"
    assert match?({:error, :invalid_input}, WID.decode("not a list")), "Non-list fails"

    IO.puts("   ✓ WID checksum validation tests passed\n")
  end

  def test_downcount_roundtrip do
    IO.puts("5. Testing Downcount encode/decode roundtrip...")

    for count <- 0..31 do
      dibits = Downcount.encode(count)

      assert length(dibits) == 4, "Downcount encode produces 4 di-bits"
      assert Enum.all?(dibits, &(&1 in 0..3)), "All di-bits in range 0-3"

      {:ok, decoded} = Downcount.decode(dibits)

      assert decoded.count == count, "Count roundtrip: #{count}"
    end

    IO.puts("   ✓ Downcount roundtrip tests passed (32 values)\n")
  end

  def test_downcount_parity_validation do
    IO.puts("6. Testing Downcount parity validation...")

    # Valid downcount
    dibits = Downcount.encode(15)
    {:ok, dc15} = Downcount.decode(dibits)
    assert dc15.count == 15, "Valid downcount decodes"

    # Check final? predicate
    {:ok, dc0} = Downcount.decode(Downcount.encode(0))
    assert Downcount.final?(dc0) == true, "Count 0 is final"

    {:ok, dc5} = Downcount.decode(Downcount.encode(5))
    assert Downcount.final?(dc5) == false, "Count 5 is not final"
    assert Downcount.remaining(dc5) == 5, "5 remaining"

    # Corrupt one di-bit
    [c3, c2, c1, c0] = dibits
    corrupted = [c3, c2, c1, rem(c0 + 1, 4)]
    assert match?({:error, :parity_mismatch}, Downcount.decode(corrupted)), "Corrupted fails parity"

    IO.puts("   ✓ Downcount parity validation tests passed\n")
  end

  # Simple assertion helper
  defp assert(true, _msg), do: :ok
  defp assert(false, msg), do: raise("Assertion failed: #{msg}")
end
