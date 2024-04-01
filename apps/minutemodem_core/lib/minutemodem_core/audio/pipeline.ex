defmodule MinuteModemCore.Audio.Pipeline do
  @moduledoc """
  Membrane audio pipeline for MinuteModem.

  Handles:
  - TX audio output (PortAudio sink) for ALE transmissions
  - RX audio input (PortAudio source) for ALE receiving (TODO)
  """

  use Membrane.Pipeline
  require Logger

  @default_sample_rate 9600

  @spec start_link(keyword()) :: {:ok, pid(), pid()} | {:error, term()}
  def start_link(opts \\ []) do
    Membrane.Pipeline.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Play audio buffer through the TX output.

  Options:
  - `:rig_id` - If provided, sends `:tx_complete` to the rig's TxFSM when playback finishes
  """
  def play_tx(audio_binary, sample_rate \\ @default_sample_rate, opts \\ []) do
    Membrane.Pipeline.call(__MODULE__, {:play_tx, audio_binary, sample_rate, opts})
  end

  @doc """
  Set the TX output device by name.
  """
  def set_tx_device(device_name) do
    Membrane.Pipeline.call(__MODULE__, {:set_tx_device, device_name})
  end

  @doc """
  Get current TX device info.
  """
  def get_tx_device do
    Membrane.Pipeline.call(__MODULE__, :get_tx_device)
  end

  ## ------------------------------------------------------------------
  ## Pipeline Callbacks
  ## ------------------------------------------------------------------

  @impl true
  def handle_init(_ctx, opts) do
    Logger.info("Initializing audio pipeline")

    # Find default output device
    default_device = find_default_output_device()

    state = %{
      tx_device_id: default_device && default_device.id,
      tx_device_name: default_device && default_device.name,
      sample_rate: Keyword.get(opts, :sample_rate, @default_sample_rate),
      playing: false,
      # Map of play_id -> rig_id for completion notifications
      active_playbacks: %{}
    }

    Logger.info("Audio Pipeline TX device: #{state.tx_device_name || "none"}")

    {[], state}
  end

  @impl true
  def handle_call({:set_tx_device, device_name}, _ctx, state) do
    device = find_device_by_name(device_name)

    if device do
      Logger.info("Audio Pipeline TX device set to: #{device_name}")
      new_state = %{state | tx_device_id: device.id, tx_device_name: device.name}
      {[reply: :ok], new_state}
    else
      Logger.warning("Audio Pipeline: device not found: #{device_name}")
      {[reply: {:error, :not_found}], state}
    end
  end

  @impl true
  def handle_call(:get_tx_device, _ctx, state) do
    {[reply: %{id: state.tx_device_id, name: state.tx_device_name}], state}
  end

  @impl true
  def handle_call({:play_tx, audio_binary, sample_rate}, ctx, state) do
    # Backwards compatibility - no opts
    handle_call({:play_tx, audio_binary, sample_rate, []}, ctx, state)
  end

  @impl true
  def handle_call({:play_tx, audio_binary, sample_rate, opts}, _ctx, state) do
    if state.tx_device_id do
      # Create a new pipeline branch for this playback
      play_id = :erlang.unique_integer([:positive])
      source_id = :"tx_source_#{play_id}"
      sink_id = :"tx_sink_#{play_id}"

      Logger.debug("Audio Pipeline: playing #{byte_size(audio_binary)} bytes @ #{sample_rate}Hz (play_id=#{play_id})")

      spec = [
        child(source_id, %MinuteModemCore.Audio.BufferSource{
          data: audio_binary,
          sample_rate: sample_rate
        })
        |> child(sink_id, %Membrane.PortAudio.Sink{
          endpoint_id: state.tx_device_id
        })
      ]

      # Track rig_id for completion notification
      rig_id = Keyword.get(opts, :rig_id)
      new_active = if rig_id do
        Map.put(state.active_playbacks, play_id, rig_id)
      else
        state.active_playbacks
      end

      {[reply: :ok, spec: spec], %{state | active_playbacks: new_active}}
    else
      Logger.warning("Audio Pipeline: no TX device configured")
      {[reply: {:error, :no_device}], state}
    end
  end

  @impl true
  def handle_element_end_of_stream(sink_id, _pad, _ctx, state) do
    # Clean up the playback branch when done
    Logger.debug("Audio Pipeline: playback complete (#{sink_id})")

    # Extract the play_id from sink_id to find the source
    case Atom.to_string(sink_id) do
      "tx_sink_" <> id_str ->
        source_id = :"tx_source_#{id_str}"
        play_id = String.to_integer(id_str)

        # Notify the TxFSM if we have a rig_id for this playback
        case Map.get(state.active_playbacks, play_id) do
          nil ->
            :ok
          rig_id ->
            notify_tx_complete(rig_id)
        end

        # Remove from tracking
        new_active = Map.delete(state.active_playbacks, play_id)

        {[remove_children: [sink_id, source_id]], %{state | active_playbacks: new_active}}
      _ ->
        {[], state}
    end
  end

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp find_default_output_device do
    Membrane.PortAudio.list_devices()
    |> Enum.find(fn d ->
      d.default_device == :output and d.max_output_channels > 0
    end)
  end

  defp find_device_by_name(name) do
    Membrane.PortAudio.list_devices()
    |> Enum.find(fn d ->
      d.name == name and d.max_output_channels > 0
    end)
  end

  defp notify_tx_complete(rig_id) do
    # Send :tx_complete to the TxFSM via its registered name
    tx_fsm = {:via, Registry, {MinuteModemCore.Modem.Registry, {rig_id, :tx}}}

    case GenServer.whereis(tx_fsm) do
      nil ->
        Logger.warning("Audio Pipeline: TxFSM not found for rig #{rig_id}")
      pid ->
        Logger.debug("Audio Pipeline: sending :tx_complete to TxFSM #{inspect(pid)}")
        send(pid, :tx_complete)
    end
  end
end
