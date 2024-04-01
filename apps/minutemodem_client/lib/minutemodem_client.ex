defmodule MinuteModemClient do
  @moduledoc """
  MinuteModem DTE Client.

  A standalone client application for testing MIL-STD-188-110D Appendix A
  modem interfaces. Provides a simple UI with:

  - Connect/disconnect to modem
  - ARM/START controls
  - Canned message buttons
  - Simple ARQ (sequence numbers, ACK, retransmit)
  - TX/RX logging

  ## Usage

  Start the client UI:

      MinuteModemClient.start()

  Or from the umbrella root:

      cd apps/minutemodem_client && mix run --no-halt
  """

  def start do
    # Ensure wx_mvu is running
    {:ok, _} = Application.ensure_all_started(:wx_mvu)

    # Start our scenes
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.UI)
    {:ok, _} = WxMVU.start_scene(MinuteModemClient.Scenes.DTE)

    :ok
  end
end
