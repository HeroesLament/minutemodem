defmodule MinuteModemCore.Audio.BufferSource do
  @moduledoc """
  Membrane source element that outputs audio from a buffer at real-time pace.
  """

  use Membrane.Source

  # Send ~50ms of audio at a time
  @chunk_duration_ms 50

  def_options data: [
                spec: binary(),
                description: "Audio data to play (s16le format)"
              ],
              sample_rate: [
                spec: pos_integer(),
                default: 48000,
                description: "Sample rate in Hz"
              ]

  def_output_pad :output,
    accepted_format: Membrane.RawAudio,
    flow_control: :push

  @impl true
  def handle_init(_ctx, opts) do
    # Calculate chunk size: sample_rate * bytes_per_sample * channels * duration
    # 48000 * 2 * 1 * 0.05 = 4800 bytes per 50ms
    chunk_size = div(opts.sample_rate * 2 * @chunk_duration_ms, 1000)

    state = %{
      data: opts.data,
      sample_rate: opts.sample_rate,
      chunk_size: chunk_size,
      stream_format_sent: false
    }
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Send stream format first
    stream_format = %Membrane.RawAudio{
      channels: 1,
      sample_rate: state.sample_rate,
      sample_format: :s16le
    }

    # Start the chunked sending timer
    actions = [
      stream_format: {:output, stream_format},
      start_timer: {:chunk_timer, Membrane.Time.milliseconds(@chunk_duration_ms)}
    ]

    {actions, %{state | stream_format_sent: true}}
  end

  @impl true
  def handle_tick(:chunk_timer, _ctx, state) do
    chunk_size = state.chunk_size

    case state.data do
      <<chunk::binary-size(chunk_size), rest::binary>> ->
        buffer = %Membrane.Buffer{payload: chunk}
        {[buffer: {:output, buffer}], %{state | data: rest}}

      <<>> ->
        # No more data, stop timer and end stream
        {[stop_timer: :chunk_timer, end_of_stream: :output], state}

      remaining when byte_size(remaining) > 0 ->
        # Send remaining data and end
        buffer = %Membrane.Buffer{payload: remaining}
        {[buffer: {:output, buffer}, stop_timer: :chunk_timer, end_of_stream: :output],
         %{state | data: <<>>}}
    end
  end
end
