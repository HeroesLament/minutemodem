defmodule MinuteModemUI.Audio.SpeakerPipeline do
  @moduledoc """
  Minimal Membrane pipeline for playing voice RX audio to the operator's speaker.

  Started by Voice.Client with speaker device ID and sample rate.
  Voice.Client pushes decoded PCM via `Pipeline.notify_child(pipeline, :source, {:audio, pcm})`.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    speaker_device_id = Keyword.fetch!(opts, :speaker_device_id)
    sample_rate = Keyword.get(opts, :sample_rate, 8000)

    spec =
      child(:source, %MinuteModemUI.Audio.PushSource{sample_rate: sample_rate})
      |> child(:sink, %Membrane.PortAudio.Sink{endpoint_id: speaker_device_id})

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info(_msg, _ctx, state) do
    {[], state}
  end
end
