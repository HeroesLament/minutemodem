defmodule MinuteModemUI.Audio.RxMonitor do
  @moduledoc """
  Read-only subscriber to a rig's RX audio stream.

  Subscribes directly to `Rig.Audio` on the core node via RPC,
  receives `{:rx_audio, rig_id, samples}` messages, and forwards
  them to the owning scene.

  This is a display-only path — no TX, no PTT, no voice. Any number
  of RxMonitors can subscribe to the same rig simultaneously.

  ## Notifications to owner

  - `{:rx_audio, rig_id, samples}`           — raw channel audio (integer list)
  - `{:rx_audio, rig_id, samples, metadata}` — with simnet metadata
  - `{:rx_monitor, :attached, rig_id}`
  - `{:rx_monitor, :detached}`
  - `{:rx_monitor, :attach_failed, reason}`
  """

  use GenServer

  require Logger

  alias MinuteModemUI.CoreClient

  defstruct [:owner, :rig_id, :audio_pid, :audio_ref]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, owner)
  end

  @doc "Subscribe to a rig's RX audio. Detaches from any current rig first."
  def attach(pid, rig_id), do: GenServer.call(pid, {:attach, rig_id})

  @doc "Unsubscribe from the current rig."
  def detach(pid), do: GenServer.call(pid, :detach)

  @doc "Return the currently attached rig_id, or nil."
  def attached_rig(pid), do: GenServer.call(pid, :attached_rig)

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(owner) do
    Process.monitor(owner)
    {:ok, %__MODULE__{owner: owner, rig_id: nil}}
  end

  @impl true
  def handle_call({:attach, rig_id}, _from, state) do
    state = do_detach(state)

    case rpc_subscribe(rig_id) do
      {:ok, audio_pid} ->
        ref = Process.monitor(audio_pid)
        Logger.debug("[RxMonitor] Subscribed to rig #{short(rig_id)}")
        notify(state.owner, {:rx_monitor, :attached, rig_id})
        {:reply, :ok, %{state | rig_id: rig_id, audio_pid: audio_pid, audio_ref: ref}}

      {:error, reason} = err ->
        Logger.warning("[RxMonitor] Subscribe failed: #{inspect(reason)}")
        notify(state.owner, {:rx_monitor, :attach_failed, reason})
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:detach, _from, state) do
    {:reply, :ok, do_detach(state)}
  end

  @impl true
  def handle_call(:attached_rig, _from, state) do
    {:reply, state.rig_id, state}
  end

  # --- RX audio from Rig.Audio on core ---

  @impl true
  def handle_info({:rx_audio, _rig_id, _samples} = msg, state) do
    send(state.owner, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({:rx_audio, _rig_id, _samples, _metadata} = msg, state) do
    send(state.owner, msg)
    {:noreply, state}
  end

  # --- Owner died ---

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{owner: pid} = state) do
    do_detach(state)
    {:stop, :normal, state}
  end

  # --- Rig.Audio on core died (rig restarted) — resubscribe ---

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{audio_ref: ref, rig_id: rig_id} = state)
      when not is_nil(rig_id) do
    Logger.info("[RxMonitor] Rig.Audio died for #{short(rig_id)}, will resubscribe...")
    Process.send_after(self(), {:resubscribe, rig_id}, 500)
    {:noreply, %{state | audio_pid: nil, audio_ref: nil}}
  end

  @impl true
  def handle_info({:resubscribe, rig_id}, %{rig_id: rig_id} = state) do
    case rpc_subscribe(rig_id) do
      {:ok, audio_pid} ->
        ref = Process.monitor(audio_pid)
        Logger.info("[RxMonitor] Resubscribed to rig #{short(rig_id)}")
        {:noreply, %{state | audio_pid: audio_pid, audio_ref: ref}}

      {:error, reason} ->
        Logger.warning("[RxMonitor] Resubscribe failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), {:resubscribe, rig_id}, 1000)
        {:noreply, state}
    end
  end

  # Stale resubscribe for a rig we're no longer attached to
  @impl true
  def handle_info({:resubscribe, _old_rig_id}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_detach(state)
    :ok
  end

  # ===========================================================================
  # Internal
  # ===========================================================================

  defp do_detach(%{rig_id: nil} = state), do: state

  defp do_detach(%{rig_id: rig_id, audio_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    rpc_unsubscribe(rig_id)
    notify(state.owner, {:rx_monitor, :detached})
    %{state | rig_id: nil, audio_pid: nil, audio_ref: nil}
  end

  defp rpc_subscribe(rig_id) do
    node = CoreClient.core_node()

    # We must call GenServer.call directly so that self() (the RxMonitor pid)
    # is the subscriber, not an ephemeral :rpc worker process.
    case resolve_audio_pid(node, rig_id) do
      {:ok, audio_pid} ->
        GenServer.call(audio_pid, {:subscribe, self()})
        {:ok, audio_pid}

      {:error, _} = err ->
        err
    end
  end

  defp rpc_unsubscribe(rig_id) do
    node = CoreClient.core_node()

    case resolve_audio_pid(node, rig_id) do
      {:ok, audio_pid} ->
        GenServer.call(audio_pid, {:unsubscribe, self()})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp resolve_audio_pid(node, rig_id) do
    registry = MinuteModemCore.Rig.InstanceRegistry
    key = {rig_id, :audio}

    result =
      if node == Node.self() do
        Registry.lookup(registry, key)
      else
        :rpc.call(node, Registry, :lookup, [registry, key])
      end

    case result do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
      {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      _ -> {:error, :not_found}
    end
  end

  defp notify(owner, msg), do: send(owner, msg)

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(id), do: inspect(id)
end
