defmodule MinuteModemUI.Audio.Session do
  @moduledoc """
  Pure audio transport between the UI node and a core rig's AudioEndpoint.

  This is the transport layer only — it owns the Distribution connection
  to `Rig.AudioEndpoint` on the core node, relays streams in both
  directions, and handles attach/detach lifecycle. It contains no
  voice-mode logic, no PTT/VOX/BYPASS state, and no signal gating.

  Equivalent to `DTE.Client` owning the TCP socket to the modem.

  ## Streams relayed to owner

  - `{:session, :attached, rig_id}`
  - `{:session, :detached}`
  - `{:session, :attach_failed, reason}`
  - `{:session, :rig_rx, samples}`
  - `{:session, :voice_rx, pcm}`
  - `{:session, :tx_status, owner}`

  ## Commands accepted

  - `attach/2`          — attach to a rig's AudioEndpoint
  - `detach/1`          — detach from current rig
  - `voice_signal/2`    — forward a voice signal to core (pass-through)
  - `push_voice_tx/2`   — forward mic PCM to core (pass-through)
  """

  use GenServer

  require Logger

  alias MinuteModemUI.CoreClient

  defstruct [:owner, :rig_id]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, owner)
  end

  @doc "Attach to a rig's AudioEndpoint. Detaches any current rig first."
  def attach(pid, rig_id), do: GenServer.call(pid, {:attach, rig_id})

  @doc "Detach from the current rig."
  def detach(pid), do: GenServer.call(pid, :detach)

  @doc "Forward a voice signal to core AudioEndpoint (pass-through, no logic)."
  def voice_signal(pid, signal), do: GenServer.cast(pid, {:voice_signal, signal})

  @doc "Forward mic PCM to core AudioEndpoint (pass-through)."
  def push_voice_tx(pid, pcm) when is_binary(pcm), do: GenServer.cast(pid, {:push_voice_tx, pcm})

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

  # --- Attach / Detach ---

  @impl true
  def handle_call({:attach, rig_id}, _from, state) do
    state = do_detach(state)

    case rpc_attach(rig_id) do
      :ok ->
        notify(state.owner, {:session, :attached, rig_id})
        {:reply, :ok, %{state | rig_id: rig_id}}

      {:error, reason} = err ->
        Logger.warning("[Audio.Session] Attach failed: #{inspect(reason)}")
        notify(state.owner, {:session, :attach_failed, reason})
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

  # --- Pass-through commands to core ---

  @impl true
  def handle_cast({:voice_signal, signal}, %{rig_id: rig_id} = state) when rig_id != nil do
    rpc_cast(:voice_signal, [rig_id, signal])
    {:noreply, state}
  end

  def handle_cast({:voice_signal, _signal}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:push_voice_tx, pcm}, %{rig_id: rig_id} = state) when rig_id != nil do
    rpc_cast(:push_voice_tx, [rig_id, pcm])
    {:noreply, state}
  end

  def handle_cast({:push_voice_tx, _pcm}, state), do: {:noreply, state}

  # --- Streams from core AudioEndpoint ---

  @impl true
  def handle_info({:audio, _rig_id, :rig_rx, samples}, state) do
    notify(state.owner, {:session, :rig_rx, samples})
    {:noreply, state}
  end

  @impl true
  def handle_info({:audio, _rig_id, :voice_rx, pcm}, state) do
    notify(state.owner, {:session, :voice_rx, pcm})
    {:noreply, state}
  end

  @impl true
  def handle_info({:audio, _rig_id, :tx_status, owner}, state) do
    notify(state.owner, {:session, :tx_status, owner})
    {:noreply, state}
  end

  # --- Owner died ---

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{owner: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_detach(state)
    :ok
  end

  # ===========================================================================
  # Internal: RPC
  # ===========================================================================

  defp rpc_attach(rig_id) do
    me = self()

    case :rpc.call(core_node(), MinuteModemCore.Rig.AudioEndpoint, :attach, [rig_id, me]) do
      {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      result -> result
    end
  end

  defp rpc_detach(rig_id) do
    :rpc.call(core_node(), MinuteModemCore.Rig.AudioEndpoint, :detach, [rig_id])
    :ok
  rescue
    _ -> :ok
  end

  defp rpc_cast(function, args) do
    :rpc.cast(core_node(), MinuteModemCore.Rig.AudioEndpoint, function, args)
  end

  defp core_node, do: CoreClient.core_node()

  # ===========================================================================
  # Internal: Detach
  # ===========================================================================

  defp do_detach(%{rig_id: nil} = state), do: state

  defp do_detach(%{rig_id: rig_id} = state) do
    rpc_detach(rig_id)
    notify(state.owner, {:session, :detached})
    %{state | rig_id: nil}
  end

  defp notify(owner, msg), do: send(owner, msg)
end
