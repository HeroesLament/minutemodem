defmodule MinuteModemCore.Telemetry do
  @moduledoc """
  Telemetry event definitions and default handlers for MinuteModem.

  ## Event Namespace

  All events live under `[:minutemodem, ...]`. Each event is documented
  with its measurements (numeric values) and metadata (context).

  ### ALE Receiver — Signal Detection

      [:minutemodem, :ale, :signal_onset]
        measurements: %{rms: float, threshold: float, noise_floor: float}
        metadata:     %{rig_id: binary}

      [:minutemodem, :ale, :signal_offset]
        measurements: %{sample_count: integer, symbol_count: integer, duration_ms: float}
        metadata:     %{rig_id: binary}

  ### ALE Receiver — Probe Detection

      [:minutemodem, :ale, :probe]
        measurements: %{correlation: integer, offset: integer, phase_deg: integer,
                        preamble_zeros: integer, waveform_score: number}
        metadata:     %{rig_id: binary, result: :found | :not_found,
                        peak_corr: integer, peak_offset: integer}

  ### ALE Receiver — Frame Decode

      [:minutemodem, :ale, :decode]
        measurements: %{symbol_count: integer, path_metric: number,
                        path_metric_delta: number}
        metadata:     %{rig_id: binary, waveform: :deep | :fast,
                        decode_path: :soft_iq | :hard | :fast,
                        result: :ok | :error, error_reason: term | nil}

      When decode_path is :soft_iq, additional measurements are present:
        measurements: %{..., avg_llr: float, min_llr: float}

  ### ALE Receiver — PDU Decoded

      [:minutemodem, :ale, :pdu]
        measurements: %{symbol_count: integer}
        metadata:     %{rig_id: binary, pdu_type: atom, waveform: :deep | :fast}

  ## Usage

  Emit from instrumented code:

      :telemetry.execute(
        [:minutemodem, :ale, :signal_onset],
        %{rms: rms, threshold: threshold, noise_floor: noise_floor},
        %{rig_id: rig_id}
      )

  Attach handlers at application start:

      MinuteModemCore.Telemetry.attach_default_handlers()

  Or attach your own:

      :telemetry.attach("my-handler", [:minutemodem, :ale, :decode], &my_fn/4, nil)
  """

  require Logger

  @doc """
  All event names emitted by this system.
  """
  def events do
    [
      [:minutemodem, :ale, :signal_onset],
      [:minutemodem, :ale, :signal_offset],
      [:minutemodem, :ale, :probe],
      [:minutemodem, :ale, :decode],
      [:minutemodem, :ale, :pdu]
    ]
  end

  @doc """
  Attaches default logging handlers for all events.

  Call from your Application.start/2:

      MinuteModemCore.Telemetry.attach_default_handlers()
  """
  def attach_default_handlers do
    :telemetry.attach_many(
      "minutemodem-default-logger",
      events(),
      &handle_event/4,
      :log
    )
  end

  @doc """
  Detach the default logging handlers.
  """
  def detach_default_handlers do
    :telemetry.detach("minutemodem-default-logger")
  end

  # -------------------------------------------------------------------
  # Default Handler — logs telemetry events at info level
  # -------------------------------------------------------------------

  def handle_event([:minutemodem, :ale, :signal_onset], measurements, metadata, :log) do
    Logger.info(
      "[Telemetry] signal_onset rig=#{short(metadata.rig_id)} " <>
      "rms=#{round(measurements.rms)} threshold=#{round(measurements.threshold)} " <>
      "noise_floor=#{round(measurements.noise_floor)}"
    )
  end

  def handle_event([:minutemodem, :ale, :signal_offset], measurements, metadata, :log) do
    Logger.info(
      "[Telemetry] signal_offset rig=#{short(metadata.rig_id)} " <>
      "samples=#{measurements.sample_count} symbols=#{measurements.symbol_count} " <>
      "duration=#{round(measurements.duration_ms)}ms"
    )
  end

  def handle_event([:minutemodem, :ale, :probe], measurements, metadata, :log) do
    case metadata.result do
      :found ->
        Logger.info(
          "[Telemetry] probe_found rig=#{short(metadata.rig_id)} " <>
          "corr=#{measurements.correlation} offset=#{measurements.offset} " <>
          "phase=#{measurements.phase_deg}° zeros=#{measurements.preamble_zeros} " <>
          "wf_score=#{measurements.waveform_score}"
        )

      :not_found ->
        Logger.info(
          "[Telemetry] probe_not_found rig=#{short(metadata.rig_id)} " <>
          "peak_corr=#{metadata.peak_corr} peak_offset=#{metadata.peak_offset}"
        )
    end
  end

  def handle_event([:minutemodem, :ale, :decode], measurements, metadata, :log) do
    base = "[Telemetry] decode rig=#{short(metadata.rig_id)} " <>
      "wf=#{metadata.waveform} path=#{metadata.decode_path} result=#{metadata.result} " <>
      "Δpath=#{fmt(measurements.path_metric_delta)} metric=#{fmt(measurements.path_metric)}"

    llr_str = case measurements do
      %{avg_llr: avg, min_llr: min} -> " |LLR|=#{fmt(avg)} min_llr=#{fmt(min)}"
      _ -> ""
    end

    Logger.info(base <> llr_str)
  end

  def handle_event([:minutemodem, :ale, :pdu], measurements, metadata, :log) do
    Logger.info(
      "[Telemetry] pdu rig=#{short(metadata.rig_id)} " <>
      "type=#{metadata.pdu_type} wf=#{metadata.waveform} " <>
      "symbols=#{measurements.symbol_count}"
    )
  end

  # Catch-all for future events
  def handle_event(event, measurements, metadata, :log) do
    Logger.debug(
      "[Telemetry] #{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}"
    )
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp short(rig_id) when is_binary(rig_id), do: String.slice(rig_id, 0, 8)
  defp short(rig_id), do: inspect(rig_id)

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n), do: inspect(n)
end
