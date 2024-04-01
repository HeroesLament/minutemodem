defmodule Eparl.Core.RecoveryTest do
  use ExUnit.Case, async: true

  alias Eparl.Core.Recovery
  alias Eparl.Data.{Instance, Ballot}

  describe "analyze/3" do
    test "returns :not_found when all responses have nil instance" do
      responses = [
        %{instance: nil},
        %{instance: nil},
        %{instance: nil}
      ]
      assert Recovery.analyze(responses, 5, false) == :not_found
    end

    test "returns {:commit, instance} when committed instance found" do
      committed = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 5,
        deps: MapSet.new(),
        status: :committed,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      preaccepted = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 3,
        deps: MapSet.new(),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      responses = [
        %{instance: committed},
        %{instance: nil},
        %{instance: preaccepted}
      ]

      result = Recovery.analyze(responses, 5, false)
      assert {:commit, ^committed} = result
    end

    test "returns {:accept, instance} when accepted instance found" do
      accepted = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 5,
        deps: MapSet.new(),
        status: :accepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      preaccepted = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 3,
        deps: MapSet.new(),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      responses = [
        %{instance: accepted},
        %{instance: nil},
        %{instance: preaccepted}
      ]

      result = Recovery.analyze(responses, 5, false)
      assert {:accept, ^accepted} = result
    end

    test "returns {:try_preaccept, instance} when preaccepted found and leader did not respond" do
      preaccepted = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 5,
        deps: MapSet.new(),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      responses = [
        %{instance: preaccepted},
        %{instance: preaccepted},
        %{instance: nil}
      ]

      # With 2 preaccepted out of 5, that's >= half_quorum (2)
      # and leader_responded = false
      result = Recovery.analyze(responses, 5, false)
      assert {:try_preaccept, _instance} = result
    end

    test "returns {:restart_phase1, instance} when only preaccepted and leader responded" do
      preaccepted = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 5,
        deps: MapSet.new(),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      responses = [
        %{instance: preaccepted},
        %{instance: nil},
        %{instance: nil}
      ]

      # Leader responded = true means we can't use TryPreAccept
      # Only 1 preaccepted, so restart
      result = Recovery.analyze(responses, 5, true)
      assert {:restart_phase1, _instance} = result
    end

    test "merges seq and deps from multiple preaccepted responses" do
      p1 = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 5,
        deps: MapSet.new([{:b, 1}]),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      p2 = %Instance{
        id: {:a, 1},
        command: {:put, "x", 1},
        seq: 7,
        deps: MapSet.new([{:c, 2}]),
        status: :preaccepted,
        ballot: %Ballot{epoch: 0, counter: 0, replica_id: :a}
      }
      responses = [
        %{instance: p1},
        %{instance: p2},
        %{instance: nil}
      ]

      {:try_preaccept, instance} = Recovery.analyze(responses, 5, false)

      # Should have max seq
      assert instance.seq == 7
      # Should have union of deps
      assert MapSet.member?(instance.deps, {:b, 1})
      assert MapSet.member?(instance.deps, {:c, 2})
    end
  end

  describe "analyze_try_preaccept/3" do
    test "returns {:continue, quorum} when waiting for more responses" do
      responses = [
        %{ok: true, from: :a}
      ]
      possible_quorum = MapSet.new([:a, :b, :c, :d, :e])

      result = Recovery.analyze_try_preaccept(responses, 5, possible_quorum)
      # Only 1 OK, need 3 for slow quorum with cluster_size=5
      assert {:continue, _} = result
    end

    test "returns {:accept, quorum} when enough OKs" do
      responses = [
        %{ok: true, from: :a},
        %{ok: true, from: :b},
        %{ok: true, from: :c}
      ]
      possible_quorum = MapSet.new([:a, :b, :c, :d, :e])

      result = Recovery.analyze_try_preaccept(responses, 5, possible_quorum)
      # 3 OKs >= slow_quorum_size(5) = 3
      assert {:accept, _} = result
    end

    test "removes conflicting replicas from possible quorum" do
      responses = [
        %{ok: false, from: :a, conflict_replica: :x, conflict_instance: 1, conflict_status: :accepted}
      ]
      possible_quorum = MapSet.new([:a, :b, :c, :d, :e])

      result = Recovery.analyze_try_preaccept(responses, 5, possible_quorum)

      case result do
        {:continue, new_quorum} ->
          # :a had a conflict, should be removed
          refute MapSet.member?(new_quorum, :a)

        {:restart, _} ->
          # Also acceptable if quorum became impossible
          :ok
      end
    end

    test "returns {:restart, quorum} when committed conflict found" do
      responses = [
        %{ok: false, from: :a, conflict_replica: :x, conflict_instance: 1, conflict_status: :committed}
      ]
      possible_quorum = MapSet.new([:a, :b, :c, :d, :e])

      result = Recovery.analyze_try_preaccept(responses, 5, possible_quorum)
      assert {:restart, _} = result
    end

    test "returns {:restart, quorum} when too many conflicts" do
      responses = [
        %{ok: false, from: :a, conflict_replica: nil},
        %{ok: false, from: :b, conflict_replica: nil},
        %{ok: false, from: :c, conflict_replica: nil}
      ]
      # Start with small quorum
      possible_quorum = MapSet.new([:a, :b, :c, :d, :e])

      result = Recovery.analyze_try_preaccept(responses, 5, possible_quorum)
      # After removing a, b, c - only d, e left (2), not enough for quorum
      assert {:restart, _} = result
    end
  end
end
