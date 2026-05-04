defmodule LicenseUI.Scenes.License do
  @moduledoc """
  wx_mvu scene for license activation.

  Shows license status and handles activation via:
  - Pasting a license key
  - Loading a .mmlic file
  - Online activation (phone home for assertion)

  The scene closes itself on success. The calling application should
  monitor the scene process and start its own UI when the scene exits.

  ## States

  - :checking     — initial check on startup
  - :licensed     — valid license + assertion, show status
  - :unlicensed   — no license, show activation form
  - :needs_assert — key valid but no assertion, offer online activation
  - :expired      — license expired, offer re-activation
  - :error        — something went wrong
  - :closing      — shutting down the window
  """

  use WxMVU.Scene

  ## ------------------------------------------------------------------
  ## Init
  ## ------------------------------------------------------------------

  def init(_opts) do
    model = %{
      state: :checking,
      key_input: "",
      file_path: nil,
      license: nil,
      error_msg: nil,
      days_remaining: nil
    }

    check_license(model)
  end

  ## ------------------------------------------------------------------
  ## Handle Event — Navigation
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :lic_activate_btn, :click}, model) do
    do_activate_key(model)
  end

  def handle_event({:ui_event, :lic_file_btn, :click}, model) do
    if model.file_path && model.file_path != "" do
      do_activate_file(model)
    else
      %{model | error_msg: "Select a .mmlic file first"}
    end
  end

  def handle_event({:ui_event, :lic_online_btn, :click}, model) do
    do_online_assertion(model)
  end

  def handle_event({:ui_event, :lic_retry_btn, :click}, model) do
    %{model | state: :unlicensed, error_msg: nil}
  end

  def handle_event({:ui_event, :license, :close_window, _}, model) do
    model
  end

  def handle_event({:ui_event, :lic_continue_btn, :click}, model) do
    spawn(fn ->
      Process.sleep(100)
      WxMVU.stop_scene(LicenseUI.Scenes.License)
    end)
    %{model | state: :closing}
  end

  def handle_event({:ui_event, :lic_deactivate_btn, :click}, model) do
    LicenseCore.deactivate()
    %{model | state: :unlicensed, license: nil, error_msg: nil}
  end

  ## ------------------------------------------------------------------
  ## Handle Event — Form inputs
  ## ------------------------------------------------------------------

  def handle_event({:ui_event, :lic_key_input, :change, value}, model) do
    %{model | key_input: value}
  end

  def handle_event({:ui_event, :lic_file_picker, :change, path}, model) do
    %{model | file_path: path}
  end

  def handle_event(_event, model), do: model

  ## ------------------------------------------------------------------
  ## View
  ## ------------------------------------------------------------------

  def view(model) do
    base = [
      {:ensure_window, :license, title: "MinuteModem License"},
      {:ensure_panel, :lic_root, :license, []}
    ]

    content = case model.state do
      :checking     -> view_checking()
      :licensed     -> view_licensed(model)
      :unlicensed   -> view_unlicensed(model)
      :needs_assert -> view_needs_assertion(model)
      :expired      -> view_expired(model)
      :error        -> view_error(model)
      :closing      -> [{:destroy_window, :license}]
    end

    if model.state == :closing do
      [{:destroy_window, :license}]
    else
      base ++ content ++ [{:refresh, :license}]
    end
  end

  ## ------------------------------------------------------------------
  ## View: Checking
  ## ------------------------------------------------------------------

  defp view_checking do
    [
      {:ensure_widget, :lic_checking_label, :static_text, :lic_root,
       label: "Checking license..."},

      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_checking_label, flag: :align_center_horizontal}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## View: Licensed
  ## ------------------------------------------------------------------

  defp view_licensed(model) do
    l = model.license
    days = model.days_remaining

    expiry_label = cond do
      days && days <= 7  -> "⚠ Expires in #{days} days!"
      days && days <= 30 -> "Expires in #{days} days"
      days               -> "Expires: #{Date.to_iso8601(l.expires)} (#{days} days)"
      true               -> "Expires: #{Date.to_iso8601(l.expires)}"
    end

    [
      {:ensure_widget, :lic_status_icon, :static_text, :lic_root,
       label: "✓ Licensed"},
      {:ensure_widget, :lic_email_label, :static_text, :lic_root,
       label: "Account: #{l.email}"},
      {:ensure_widget, :lic_tier_label, :static_text, :lic_root,
       label: "Tier: #{l.tier}"},
      {:ensure_widget, :lic_expiry_label, :static_text, :lic_root,
       label: expiry_label},

      {:ensure_widget, :lic_continue_btn, :button, :lic_root,
       label: "Continue"},
      {:ensure_widget, :lic_deactivate_btn, :button, :lic_root,
       label: "Deactivate"},

      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_status_icon, flag: :align_center_horizontal},
          {:spacer, 10},
          :lic_email_label,
          :lic_tier_label,
          :lic_expiry_label,
          {:spacer, 20},
          {:hbox, [], [:lic_continue_btn, {:spacer, 10}, :lic_deactivate_btn]}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## View: Unlicensed
  ## ------------------------------------------------------------------

  defp view_unlicensed(model) do
    [
      {:ensure_widget, :lic_title, :static_text, :lic_root,
       label: "MinuteModem License Activation"},

      {:ensure_widget, :lic_key_label, :static_text, :lic_root,
       label: "License Key:"},
      {:ensure_widget, :lic_key_input, :text_ctrl, :lic_root,
       value: model.key_input},
      {:ensure_widget, :lic_activate_btn, :button, :lic_root,
       label: "Activate"},

      {:ensure_widget, :lic_file_label, :static_text, :lic_root,
       label: "Or paste .mmlic file path:"},
      {:ensure_widget, :lic_file_picker, :text_ctrl, :lic_root,
       value: ""},
      {:ensure_widget, :lic_file_btn, :button, :lic_root,
       label: "Activate from File"}
    ] ++ error_widget(model) ++ [
      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_title, flag: :align_center_horizontal},
          {:spacer, 15},
          :lic_key_label,
          :lic_key_input,
          {:spacer, 5},
          {:lic_activate_btn, flag: :align_right},
          {:spacer, 15},
          :lic_file_label,
          :lic_file_picker,
          {:spacer, 5},
          {:lic_file_btn, flag: :align_right}
        ] ++ if(model.error_msg, do: [{:spacer, 10}, :lic_error_label], else: [])}}
    ]
  end

  ## ------------------------------------------------------------------
  ## View: Needs Assertion
  ## ------------------------------------------------------------------

  defp view_needs_assertion(model) do
    l = model.license

    [
      {:ensure_widget, :lic_assert_title, :static_text, :lic_root,
       label: "License Valid — Activation Required"},
      {:ensure_widget, :lic_assert_email, :static_text, :lic_root,
       label: "Account: #{l.email}"},
      {:ensure_widget, :lic_assert_info, :static_text, :lic_root,
       label: "This machine needs to be activated. Connect to the internet and click below."},

      {:ensure_widget, :lic_online_btn, :button, :lic_root,
       label: "Activate Online"},
      {:ensure_widget, :lic_retry_btn, :button, :lic_root,
       label: "Enter Different Key"}
    ] ++ error_widget(model) ++ [
      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_assert_title, flag: :align_center_horizontal},
          {:spacer, 10},
          :lic_assert_email,
          :lic_assert_info,
          {:spacer, 15},
          {:hbox, [], [:lic_online_btn, {:spacer, 10}, :lic_retry_btn]}
        ] ++ if(model.error_msg, do: [{:spacer, 10}, :lic_error_label], else: [])}}
    ]
  end

  ## ------------------------------------------------------------------
  ## View: Expired
  ## ------------------------------------------------------------------

  defp view_expired(model) do
    l = model.license

    [
      {:ensure_widget, :lic_exp_title, :static_text, :lic_root,
       label: "⚠ License Expired"},
      {:ensure_widget, :lic_exp_email, :static_text, :lic_root,
       label: "Account: #{l.email} — expired #{Date.to_iso8601(l.expires)}"},
      {:ensure_widget, :lic_exp_info, :static_text, :lic_root,
       label: "Enter a new license key or load an updated .mmlic file."},

      {:ensure_widget, :lic_key_label, :static_text, :lic_root,
       label: "License Key:"},
      {:ensure_widget, :lic_key_input, :text_ctrl, :lic_root,
       value: model.key_input},
      {:ensure_widget, :lic_activate_btn, :button, :lic_root,
       label: "Activate"},

      {:ensure_widget, :lic_file_label, :static_text, :lic_root,
       label: "Or paste .mmlic file path:"},
      {:ensure_widget, :lic_file_picker, :text_ctrl, :lic_root,
       value: ""},
      {:ensure_widget, :lic_file_btn, :button, :lic_root,
       label: "Activate from File"}
    ] ++ error_widget(model) ++ [
      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_exp_title, flag: :align_center_horizontal},
          {:spacer, 5},
          :lic_exp_email,
          :lic_exp_info,
          {:spacer, 15},
          :lic_key_label,
          :lic_key_input,
          {:spacer, 5},
          {:lic_activate_btn, flag: :align_right},
          {:spacer, 15},
          :lic_file_label,
          :lic_file_picker,
          {:spacer, 5},
          {:lic_file_btn, flag: :align_right}
        ] ++ if(model.error_msg, do: [{:spacer, 10}, :lic_error_label], else: [])}}
    ]
  end

  ## ------------------------------------------------------------------
  ## View: Error
  ## ------------------------------------------------------------------

  defp view_error(model) do
    [
      {:ensure_widget, :lic_error_title, :static_text, :lic_root,
       label: "✗ Activation Error"},
      {:ensure_widget, :lic_error_detail, :static_text, :lic_root,
       label: model.error_msg || "Unknown error"},
      {:ensure_widget, :lic_retry_btn, :button, :lic_root,
       label: "Try Again"},

      {:layout, :lic_root,
       {:vbox, [padding: 20],
        [
          {:lic_error_title, flag: :align_center_horizontal},
          {:spacer, 10},
          :lic_error_detail,
          {:spacer, 15},
          {:lic_retry_btn, flag: :align_center_horizontal}
        ]}}
    ]
  end

  ## ------------------------------------------------------------------
  ## Shared view helpers
  ## ------------------------------------------------------------------

  defp error_widget(%{error_msg: nil}), do: []
  defp error_widget(%{error_msg: msg}) do
    [
      {:ensure_widget, :lic_error_label, :static_text, :lic_root,
       label: "✗ #{msg}"}
    ]
  end

  ## ------------------------------------------------------------------
  ## Actions
  ## ------------------------------------------------------------------

  defp check_license(model) do
    case LicenseCore.status() do
      %{status: :open_source} ->
        %{model | state: :licensed}

      %{status: :active, license: license, days_remaining: days} ->
        %{model | state: :licensed, license: license, days_remaining: days}

      %{status: :expired, license: license} ->
        %{model | state: :expired, license: license}

      %{status: :needs_assertion, license: license} ->
        %{model | state: :needs_assert, license: license}

      %{status: :unlicensed} ->
        %{model | state: :unlicensed}

      %{status: :invalid, message: msg} ->
        %{model | state: :unlicensed, error_msg: msg}

      %{status: :invalid_assertion, license: license, message: msg} ->
        %{model | state: :needs_assert, license: license, error_msg: msg}
    end
  end

  defp do_activate_key(model) do
    key = String.trim(model.key_input)

    if key == "" or not String.starts_with?(key, "MM-") do
      %{model | error_msg: "Enter a valid license key (starts with MM-)"}
    else
      case LicenseCore.activate(key) do
        {:ok, license} ->
          days = Date.diff(license.expires, Date.utc_today())
          %{model | state: :licensed, license: license, days_remaining: days, error_msg: nil}

        {:ok, license, :needs_assertion} ->
          %{model | state: :needs_assert, license: license, error_msg: nil}

        {:ok, license, {:assertion_failed, reason}} ->
          %{model | state: :needs_assert, license: license,
            error_msg: "Key valid but activation failed: #{inspect(reason)}"}

        {:error, :expired} ->
          %{model | error_msg: "That license key has expired."}

        {:error, :invalid_signature} ->
          %{model | error_msg: "Invalid license key. Please check and try again."}

        {:error, :activation_denied} ->
          %{model | error_msg: "Activation denied — seat limit may be exceeded."}

        {:error, reason} ->
          %{model | error_msg: "Activation error: #{inspect(reason)}"}
      end
    end
  end

  defp do_activate_file(model) do
    case LicenseCore.activate_from_file(model.file_path) do
      {:ok, license} ->
        days = Date.diff(license.expires, Date.utc_today())
        %{model | state: :licensed, license: license, days_remaining: days, error_msg: nil}

      {:ok, license, :needs_assertion} ->
        %{model | state: :needs_assert, license: license,
          error_msg: "File has no assertion — activate online or get a newer .mmlic"}

      {:error, {:bad_assertion, reason}} ->
        %{model | error_msg: "Invalid assertion in file: #{inspect(reason)}"}

      {:error, reason} ->
        %{model | error_msg: "Failed to load file: #{inspect(reason)}"}
    end
  end

  defp do_online_assertion(model) do
    case LicenseCore.Store.load() do
      {:ok, key_string} ->
        case LicenseCore.ActivationReporter.request_assertion(key_string) do
          {:ok, assertion_string} ->
            case LicenseCore.Assertion.verify(assertion_string) do
              {:ok, _} ->
                LicenseCore.Store.save_assertion(assertion_string)
                days = if model.license, do: Date.diff(model.license.expires, Date.utc_today())
                %{model | state: :licensed, days_remaining: days, error_msg: nil}

              {:error, reason} ->
                %{model | error_msg: "Server returned invalid assertion: #{inspect(reason)}"}
            end

          {:error, :seat_limit_exceeded} ->
            %{model | error_msg: "Seat limit exceeded. Contact your administrator."}

          {:error, :denied} ->
            %{model | error_msg: "Activation denied by server."}

          {:error, :not_configured} ->
            %{model | error_msg: "No activation server configured. Use a .mmlic file."}

          {:error, reason} ->
            %{model | error_msg: "Online activation failed: #{inspect(reason)}"}
        end

      :error ->
        %{model | state: :unlicensed, error_msg: "No license key on disk."}
    end
  end
end
