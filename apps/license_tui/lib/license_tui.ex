defmodule LicenseTUI do
  @moduledoc """
  Terminal-based license activation for MinuteModem.

  Used in headless releases and as a fallback when no GUI is available.

  ## Usage from a release

      # Interactive — prompts for key input
      minutemodem_core eval 'LicenseTUI.activate()'

      # One-shot — pass the key directly
      minutemodem_core eval 'LicenseTUI.activate("MM-abc123...")'

  """

  @doc """
  Activate a license by passing the key string directly.
  Verifies and stores the key, prints the result.
  """
  def activate(key_string) when is_binary(key_string) do
    header()

    case LicenseCore.activate(key_string) do
      {:ok, license} ->
        success(license)
        :ok

      {:error, reason} ->
        failure(reason)
        {:error, reason}
    end
  end

  @doc """
  Interactive activation — prompts the user for a license key.
  """
  def activate do
    header()

    case LicenseCore.check() do
      :ok ->
        {:ok, key} = LicenseCore.Store.load()
        {:ok, license} = LicenseCore.verify(key)

        Owl.IO.puts([
          Owl.Data.tag("✓ ", :green),
          "Already activated for ",
          Owl.Data.tag(license.email, :cyan),
          " (expires ",
          Owl.Data.tag(Date.to_iso8601(license.expires), :yellow),
          ")"
        ])

        Owl.IO.puts("")

        case Owl.IO.select(["Keep current license", "Enter a new license"],
               label: "What would you like to do?"
             ) do
          "Keep current license" ->
            :ok

          "Enter a new license" ->
            prompt_and_activate()
        end

      _ ->
        prompt_and_activate()
    end
  end

  @doc """
  Show the current license status.
  """
  def status do
    header()

    case LicenseCore.check() do
      :ok ->
        {:ok, key} = LicenseCore.Store.load()
        {:ok, license} = LicenseCore.verify(key)
        success(license)

      {:expired, license} ->
        Owl.IO.puts([
          Owl.Data.tag("✗ ", :red),
          "License expired on ",
          Owl.Data.tag(Date.to_iso8601(license.expires), :red)
        ])

      :unlicensed ->
        Owl.IO.puts([
          Owl.Data.tag("✗ ", :red),
          "No license found. Run: ",
          Owl.Data.tag("minutemodem eval 'LicenseTUI.activate()'", :cyan)
        ])

      {:error, reason} ->
        Owl.IO.puts([
          Owl.Data.tag("✗ ", :red),
          "License error: #{inspect(reason)}"
        ])
    end
  end

  # ---------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------

  defp prompt_and_activate do
    Owl.IO.puts("")

    key =
      Owl.IO.input(
        label: "Paste your license key",
        cast: fn input ->
          trimmed = String.trim(input)

          if String.starts_with?(trimmed, "MM-") do
            {:ok, trimmed}
          else
            {:error, "Key must start with MM-"}
          end
        end
      )

    Owl.IO.puts("")

    case LicenseCore.activate(key) do
      {:ok, license} ->
        success(license)
        :ok

      {:error, :expired} ->
        Owl.IO.puts([Owl.Data.tag("✗ ", :red), "That license key has expired."])
        {:error, :expired}

      {:error, :invalid_signature} ->
        Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Invalid license key. Please check and try again."])
        {:error, :invalid_signature}

      {:error, reason} ->
        Owl.IO.puts([Owl.Data.tag("✗ ", :red), "Error: #{inspect(reason)}"])
        {:error, reason}
    end
  end

  defp header do
    box =
      Owl.Box.new("MinuteModem License Activation",
        padding: 1,
        border_style: :solid_rounded
      )

    Owl.IO.puts(box)
    Owl.IO.puts("")
  end

  defp success(license) do
    Owl.IO.puts([
      Owl.Data.tag("✓ ", :green),
      "License activated!"
    ])

    Owl.IO.puts([
      "  Account: ",
      Owl.Data.tag(license.email, :cyan)
    ])

    Owl.IO.puts([
      "  Tier:    ",
      Owl.Data.tag(license.tier, :cyan)
    ])

    Owl.IO.puts([
      "  Expires: ",
      Owl.Data.tag(Date.to_iso8601(license.expires), :yellow)
    ])
  end

  defp failure(reason) do
    msg =
      case reason do
        :invalid_signature -> "Invalid license key"
        :invalid_format -> "Malformed key (expected MM-...)"
        :invalid_encoding -> "Key contains invalid characters"
        :expired -> "License has expired"
        other -> "Error: #{inspect(other)}"
      end

    Owl.IO.puts([Owl.Data.tag("✗ ", :red), msg])
  end
end
