defmodule MinuteModemUI.Audio.PushSource do
  @moduledoc """
  Membrane source element that accepts PCM pushed from an external process.

  Used by Voice.Client to stream decoded voice RX into a PortAudio Sink.
  The owning process sends `{:push_audio, pcm}` to the pipeline, which
  routes it here via `handle_parent_notification`.

  ## Usage in pipeline spec

      child(:source, %MinuteModemUI.Audio.PushSource{sample_rate: 8000})
      |> child(:sink, %Membrane.PortAudio.Sink{endpoint_id: device_id})

  Then from the pipeline owner:

      Membrane.Pipeline.notify_child(pipeline, :source, {:audio, pcm})
  """

  use Membrane.Source

  def_options sample_rate: [
                spec: pos_integer(),
                default: 8000,
                description: "Sample rate in Hz"
              ]

  def_output_pad :output,
    accepted_format: Membrane.RawAudio,
    flow_control: :push

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{sample_rate: opts.sample_rate, playing: false}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %Membrane.RawAudio{
      channels: 1,
      sample_rate: state.sample_rate,
      sample_format: :s16le
    }

    {[stream_format: {:output, stream_format}], %{state | playing: true}}
  end

  @impl true
  def handle_parent_notification({:audio, pcm}, _ctx, %{playing: true} = state)
      when is_binary(pcm) and byte_size(pcm) > 0 do
    buffer = %Membrane.Buffer{payload: pcm}
    {[buffer: {:output, buffer}], state}
  end

  def handle_parent_notification(_msg, _ctx, state) do
    {[], state}
  end
end
