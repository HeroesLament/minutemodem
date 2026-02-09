defmodule LicenseCLI.Fmt do
  @moduledoc """
  Output formatting helpers for the CLI.
  """

  def ok(msg), do: Owl.IO.puts([Owl.Data.tag("✓ ", :green), msg])
  def err(msg), do: Owl.IO.puts([Owl.Data.tag("✗ ", :red), msg])
  def warn(msg), do: Owl.IO.puts([Owl.Data.tag("⚠ ", :yellow), msg])
  def info(msg), do: Owl.IO.puts(["  ", msg])

  def license_table(licenses) when is_list(licenses) do
    if licenses == [] do
      info("No licenses found.")
    else
      header = "  #{pad("EMAIL", 30)} #{pad("TIER", 12)} #{pad("EXPIRES", 12)} #{pad("STATUS", 12)} ID"
      Owl.IO.puts([Owl.Data.tag(header, :cyan)])

      for l <- licenses do
        status_color = status_color(l["status"])

        Owl.IO.puts([
          "  ",
          pad(l["email"] || "", 30), " ",
          pad(l["tier"] || "", 12), " ",
          pad(l["expires"] || "", 12), " ",
          Owl.Data.tag(pad(l["status"] || "", 12), status_color), " ",
          String.slice(l["id"] || "", 0, 8), "..."
        ])
      end

      info("\n  Total: #{length(licenses)}")
    end
  end

  def license_detail(l) do
    Owl.IO.puts([
      "\n",
      Owl.Data.tag("  License: ", :cyan), l["id"], "\n",
      "    Email:   ", l["email"] || "", "\n",
      "    Tier:    ", l["tier"] || "", "\n",
      "    Expires: ", l["expires"] || "", "\n",
      "    Status:  ", Owl.Data.tag(l["status"] || "", status_color(l["status"])), "\n",
      "    Notes:   ", l["notes"] || "(none)", "\n",
      "    Issued:  ", l["issued_at"] || "", "\n"
    ])

    if key = l["key_string"] do
      Owl.IO.puts([Owl.Data.tag("    Key:\n", :cyan), "    ", key, "\n"])
    end
  end

  def activation_table(activations) do
    if activations == [] do
      info("No activations.")
    else
      for a <- activations do
        Owl.IO.puts([
          "  ",
          pad(a["hostname"] || "unknown", 20), " ",
          pad(a["os"] || "", 15), " ",
          pad(a["arch"] || "", 15), " ",
          pad(a["ip"] || "", 16), " ",
          "last: ", a["last_seen"] || ""
        ])
      end

      info("\n  Total: #{length(activations)}")
    end
  end

  defp pad(str, width) do
    String.pad_trailing(String.slice(str, 0, width), width)
  end

  defp status_color("active"), do: :green
  defp status_color("expired"), do: :red
  defp status_color("revoked"), do: :red
  defp status_color("refunded"), do: :yellow
  defp status_color("superseded"), do: :light_black
  defp status_color("transferred"), do: :cyan
  defp status_color(_), do: :default
end
