defmodule Eparl.Core.QuorumTest do
  use ExUnit.Case, async: true

  alias Eparl.Core.Quorum

  describe "fast_quorum_size/1" do
    test "calculates F + floor(F+1)/2 + 1 where F = floor((N-1)/2)" do
      # N=3: F=1, fast = 1 + 1 + 1 = 3
      assert Quorum.fast_quorum_size(3) == 3

      # N=5: F=2, fast = 2 + 1 + 1 = 4
      assert Quorum.fast_quorum_size(5) == 4

      # N=7: F=3, fast = 3 + 2 + 1 = 6
      assert Quorum.fast_quorum_size(7) == 6

      # N=9: F=4, fast = 4 + 2 + 1 = 7
      assert Quorum.fast_quorum_size(9) == 7
    end
  end

  describe "slow_quorum_size/1" do
    test "calculates floor(N/2) + 1 (simple majority)" do
      assert Quorum.slow_quorum_size(3) == 2
      assert Quorum.slow_quorum_size(5) == 3
      assert Quorum.slow_quorum_size(7) == 4
      assert Quorum.slow_quorum_size(9) == 5
    end
  end

  describe "has_fast_quorum?/2" do
    test "returns true when responses >= fast quorum size" do
      responses = [%{}, %{}, %{}]
      assert Quorum.has_fast_quorum?(responses, 3) == true
    end

    test "returns false when responses < fast quorum size" do
      responses = [%{}, %{}]
      assert Quorum.has_fast_quorum?(responses, 3) == false
    end
  end

  describe "has_slow_quorum?/2" do
    test "returns true when responses >= slow quorum size" do
      responses = [%{}, %{}]
      assert Quorum.has_slow_quorum?(responses, 3) == true
    end

    test "returns false when responses < slow quorum size" do
      responses = [%{}]
      assert Quorum.has_slow_quorum?(responses, 3) == false
    end
  end
end
