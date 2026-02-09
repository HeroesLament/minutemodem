defmodule LicenseCLI do
  @moduledoc """
  MinuteModem License CLI — `mmlicense`

  Admin tool for managing licenses via the LicenseAPI REST server.

  ## Setup

      mmlicense config --api-url https://license.minutemodem.com --token mm_admin_...

  ## Commands

      mmlicense issue --email user@example.com --tier pro --expires 2027-02-08
      mmlicense issue-trial --email user@example.com [--days 30]
      mmlicense bulk --file licenses.csv
      mmlicense list [--status active] [--tier pro] [--email user@...]
      mmlicense inspect ID_OR_EMAIL
      mmlicense renew ID --expires 2028-02-08
      mmlicense change-tier ID --tier enterprise
      mmlicense transfer ID --email new@owner.com
      mmlicense revoke ID
      mmlicense refund ID
      mmlicense note ID --note "Support call resolved"
      mmlicense activations ID
      mmlicense download ID [--output ./license.mmlic]
      mmlicense search QUERY
      mmlicense expiring [--days 30]
      mmlicense stats
      mmlicense export [--status active]
      mmlicense health
  """

  alias LicenseCLI.{Client, Config, Fmt}

  def main(args) do
    case args do
      ["config" | rest] -> cmd_config(rest)
      ["health" | _] -> cmd_health()
      ["issue" | rest] -> cmd_issue(rest)
      ["issue-trial" | rest] -> cmd_issue_trial(rest)
      ["bulk" | rest] -> cmd_bulk(rest)
      ["list" | rest] -> cmd_list(rest)
      ["inspect" | rest] -> cmd_inspect(rest)
      ["renew" | rest] -> cmd_renew(rest)
      ["change-tier" | rest] -> cmd_change_tier(rest)
      ["transfer" | rest] -> cmd_transfer(rest)
      ["revoke" | rest] -> cmd_revoke(rest)
      ["refund" | rest] -> cmd_refund(rest)
      ["note" | rest] -> cmd_note(rest)
      ["activations" | rest] -> cmd_activations(rest)
      ["download" | rest] -> cmd_download(rest)
      ["search" | rest] -> cmd_search(rest)
      ["expiring" | rest] -> cmd_expiring(rest)
      ["stats" | _] -> cmd_stats()
      ["export" | rest] -> cmd_export(rest)
      ["help" | _] -> cmd_help()
      [] -> cmd_help()
      [cmd | _] -> Fmt.err("Unknown command: #{cmd}. Run `mmlicense help` for usage.")
    end
  end

  # =================================================================
  # Config
  # =================================================================

  defp cmd_config(args) do
    opts = parse_opts(args, [:api_url, :token])
    api_url = opts[:api_url]
    token = opts[:token]

    cond do
      api_url && token ->
        Config.save(api_url, token)

      true ->
        case Config.load() do
          nil -> Fmt.err("Not configured. Run: mmlicense config --api-url URL --token TOKEN")
          config ->
            Fmt.info("API URL: #{config.api_url}")
            Fmt.info("Token:   #{String.slice(config.token, 0, 16)}...")
        end
    end
  end

  # =================================================================
  # Health
  # =================================================================

  defp cmd_health do
    config = Config.load!()

    case Client.get("/health", %{config | api_url: strip_api(config.api_url)}) do
      {:ok, 200, body} ->
        Fmt.ok("Server is up")
        Fmt.info("Provisioned: #{body["provisioned"]}")

      {:ok, status, body} ->
        Fmt.err("Server returned #{status}: #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Issue
  # =================================================================

  defp cmd_issue(args) do
    config = Config.load!()
    opts = parse_opts(args, [:email, :tier, :expires, :notes])

    email = opts[:email] || ask("Email:")
    tier = opts[:tier] || "standard"
    expires = opts[:expires] || ask("Expires (YYYY-MM-DD):")
    notes = opts[:notes]

    body = %{"email" => email, "tier" => tier, "expires" => expires}
    body = if notes, do: Map.put(body, "notes", notes), else: body

    case Client.post("/api/licenses", body, config) do
      {:ok, 201, %{"license" => l}} ->
        Fmt.ok("License issued!")
        Fmt.license_detail(l)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_issue_trial(args) do
    config = Config.load!()
    opts = parse_opts(args, [:email, :days])

    email = opts[:email] || ask("Email:")
    days = String.to_integer(opts[:days] || "30")

    {:ok, today} = Date.new(Date.utc_today().year, Date.utc_today().month, Date.utc_today().day)
    expires = Date.add(today, days) |> Date.to_iso8601()

    body = %{"email" => email, "tier" => "trial", "expires" => expires, "notes" => "Trial — #{days} days"}

    case Client.post("/api/licenses", body, config) do
      {:ok, 201, %{"license" => l}} ->
        Fmt.ok("Trial license issued! (#{days} days)")
        Fmt.license_detail(l)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Bulk
  # =================================================================

  defp cmd_bulk(args) do
    config = Config.load!()
    opts = parse_opts(args, [:file])

    file = opts[:file] || hd(args)

    case File.read(file) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)
        # Skip header if present
        lines = if String.contains?(hd(lines), "email"), do: tl(lines), else: lines

        licenses =
          Enum.map(lines, fn line ->
            parts = String.split(line, ",", trim: true) |> Enum.map(&String.trim/1)

            case parts do
              [email, tier, expires] -> %{"email" => email, "tier" => tier, "expires" => expires}
              [email, tier, expires | _] -> %{"email" => email, "tier" => tier, "expires" => expires}
              [email] -> %{"email" => email, "tier" => "standard", "expires" => default_expiry()}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        Fmt.info("Issuing #{length(licenses)} licenses...")

        case Client.post("/api/licenses/bulk", %{"licenses" => licenses}, config) do
          {:ok, 201, %{"results" => results}} ->
            ok = Enum.count(results, &(&1["status"] == "created"))
            Fmt.ok("#{ok}/#{length(results)} licenses issued")

            for r <- results do
              if r["status"] == "created" do
                Fmt.info("  ✓ #{r["email"]}: #{String.slice(r["key_string"], 0, 40)}...")
              else
                Fmt.info("  ✗ #{r["email"] || "?"}: #{r["reason"]}")
              end
            end

          {:ok, status, body} ->
            Fmt.err("Failed (#{status}): #{inspect(body)}")

          {:error, reason} ->
            Fmt.err("Connection failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Fmt.err("Can't read file #{file}: #{inspect(reason)}")
    end
  end

  # =================================================================
  # List / Inspect / Search
  # =================================================================

  defp cmd_list(args) do
    config = Config.load!()
    opts = parse_opts(args, [:status, :tier, :email, :q])

    query =
      Enum.flat_map([:status, :tier, :email, :q], fn key ->
        if v = opts[key], do: ["#{key}=#{URI.encode(v)}"], else: []
      end)

    path = "/api/licenses" <> if(query != [], do: "?" <> Enum.join(query, "&"), else: "")

    case Client.get(path, config) do
      {:ok, 200, %{"licenses" => licenses}} ->
        Fmt.license_table(licenses)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_inspect(args) do
    config = Config.load!()
    id_or_email = hd(args)

    # If it looks like an email, search by email
    if String.contains?(id_or_email, "@") do
      case Client.get("/api/licenses?email=#{URI.encode(id_or_email)}", config) do
        {:ok, 200, %{"licenses" => licenses}} ->
          for l <- licenses, do: Fmt.license_detail(l)

        {:ok, status, body} ->
          Fmt.err("Failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          Fmt.err("Connection failed: #{inspect(reason)}")
      end
    else
      case Client.get("/api/licenses/#{id_or_email}", config) do
        {:ok, 200, %{"license" => l}} ->
          Fmt.license_detail(l)

        {:ok, status, body} ->
          Fmt.err("Failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          Fmt.err("Connection failed: #{inspect(reason)}")
      end
    end
  end

  defp cmd_search(args) do
    config = Config.load!()
    query = Enum.join(args, " ")

    case Client.get("/api/licenses?q=#{URI.encode(query)}", config) do
      {:ok, 200, %{"licenses" => licenses}} ->
        Fmt.ok("Search results for \"#{query}\":")
        Fmt.license_table(licenses)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Lifecycle operations
  # =================================================================

  defp cmd_renew(args) do
    config = Config.load!()
    opts = parse_opts(args, [:expires])
    id = find_positional(args)
    expires = opts[:expires] || ask("New expiry (YYYY-MM-DD):")

    case Client.post("/api/licenses/#{id}/renew", %{"expires" => expires}, config) do
      {:ok, 201, %{"license" => l}} ->
        Fmt.ok("License renewed!")
        Fmt.license_detail(l)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_change_tier(args) do
    config = Config.load!()
    opts = parse_opts(args, [:tier])
    id = find_positional(args)
    tier = opts[:tier] || ask("New tier:")

    case Client.post("/api/licenses/#{id}/change-tier", %{"tier" => tier}, config) do
      {:ok, 201, %{"license" => l}} ->
        Fmt.ok("Tier changed!")
        Fmt.license_detail(l)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_transfer(args) do
    config = Config.load!()
    opts = parse_opts(args, [:email])
    id = find_positional(args)
    email = opts[:email] || ask("Transfer to email:")

    case Client.post("/api/licenses/#{id}/transfer", %{"email" => email}, config) do
      {:ok, 201, %{"license" => l}} ->
        Fmt.ok("License transferred!")
        Fmt.license_detail(l)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_revoke(args) do
    config = Config.load!()
    id = find_positional(args)

    case Client.delete("/api/licenses/#{id}", config) do
      {:ok, 200, body} ->
        Fmt.ok("License revoked.")
        if note = body["note"], do: Fmt.warn(note)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_refund(args) do
    config = Config.load!()
    id = find_positional(args)

    case Client.post("/api/licenses/#{id}/refund", %{}, config) do
      {:ok, 200, body} ->
        Fmt.ok("License refunded.")
        if note = body["note"], do: Fmt.warn(note)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_note(args) do
    config = Config.load!()
    opts = parse_opts(args, [:note])
    id = find_positional(args)
    note = opts[:note] || ask("Note:")

    case Client.post("/api/licenses/#{id}/notes", %{"note" => note}, config) do
      {:ok, 200, _} -> Fmt.ok("Note added.")
      {:ok, status, body} -> Fmt.err("Failed (#{status}): #{inspect(body)}")
      {:error, reason} -> Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Activations
  # =================================================================

  defp cmd_activations(args) do
    config = Config.load!()
    id = find_positional(args)

    case Client.get("/api/licenses/#{id}/activations", config) do
      {:ok, 200, %{"activations" => activations}} ->
        Fmt.ok("Activations:")
        Fmt.activation_table(activations)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Download .mmlic
  # =================================================================

  defp cmd_download(args) do
    config = Config.load!()
    opts = parse_opts(args, [:output])
    id = find_positional(args)

    # First get the license to find the key
    case Client.get("/api/licenses/#{id}", config) do
      {:ok, 200, %{"license" => l}} ->
        filename = opts[:output] || "#{String.replace(l["email"], ~r/[^a-zA-Z0-9._-]/, "_")}.mmlic"
        File.write!(filename, l["key_string"])
        Fmt.ok("Written to #{filename}")

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Reports
  # =================================================================

  defp cmd_expiring(args) do
    config = Config.load!()
    opts = parse_opts(args, [:days])
    days = opts[:days] || "30"

    case Client.get("/api/reports/expiring?days=#{days}", config) do
      {:ok, 200, %{"licenses" => licenses, "count" => count}} ->
        Fmt.ok("#{count} licenses expiring within #{days} days:")
        Fmt.license_table(licenses)

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_stats do
    config = Config.load!()

    case Client.get("/api/reports/stats", config) do
      {:ok, 200, body} ->
        Owl.IO.puts(["\n", Owl.Data.tag("  License Stats\n", :cyan)])

        if by_status = body["by_status"] do
          Fmt.info("By status:")
          for {status, count} <- by_status, do: Fmt.info("  #{status}: #{count}")
        end

        if by_tier = body["by_tier"] do
          Fmt.info("By tier:")
          for {tier, count} <- by_tier, do: Fmt.info("  #{tier}: #{count}")
        end

        if acts = body["activations"] do
          Fmt.info("Activations: #{acts["total"]} total, #{acts["unique_machines"]} unique machines")
        end

        IO.puts("")

      {:ok, status, body} ->
        Fmt.err("Failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  defp cmd_export(args) do
    config = Config.load!()
    opts = parse_opts(args, [:status])
    status = opts[:status] || "active"

    case Client.get("/api/reports/export?status=#{status}", config) do
      {:ok, 200, %{"licenses" => licenses, "count" => count}} ->
        Fmt.ok("Exported #{count} licenses (status: #{status}):")
        for l <- licenses do
          IO.puts("#{l["email"]},#{l["tier"]},#{l["expires"]},#{l["key_string"]}")
        end

      {:ok, status_code, body} ->
        Fmt.err("Failed (#{status_code}): #{inspect(body)}")

      {:error, reason} ->
        Fmt.err("Connection failed: #{inspect(reason)}")
    end
  end

  # =================================================================
  # Help
  # =================================================================

  defp cmd_help do
    IO.puts("""
    mmlicense — MinuteModem License Manager

    Setup:
      mmlicense config --api-url URL --token TOKEN

    Issue:
      mmlicense issue --email EMAIL --tier TIER --expires YYYY-MM-DD
      mmlicense issue-trial --email EMAIL [--days 30]
      mmlicense bulk --file licenses.csv

    Manage:
      mmlicense list [--status active] [--tier pro] [--email EMAIL]
      mmlicense inspect ID_OR_EMAIL
      mmlicense renew ID --expires YYYY-MM-DD
      mmlicense change-tier ID --tier TIER
      mmlicense transfer ID --email NEW_EMAIL
      mmlicense revoke ID
      mmlicense refund ID
      mmlicense note ID --note "text"
      mmlicense download ID [--output file.mmlic]
      mmlicense search QUERY

    Reports:
      mmlicense expiring [--days 30]
      mmlicense stats
      mmlicense export [--status active]

    Other:
      mmlicense health
      mmlicense help
    """)
  end

  # =================================================================
  # Arg parsing helpers
  # =================================================================

  defp parse_opts(args, known_keys) do
    known_flags = Enum.map(known_keys, fn k -> "--#{String.replace(to_string(k), "_", "-")}" end)

    args
    |> Enum.chunk_every(2, 1)
    |> Enum.reduce(%{}, fn
      [flag, value], acc when is_binary(flag) and is_binary(value) ->
        if flag in known_flags and not String.starts_with?(value, "--") do
          key = flag |> String.trim_leading("--") |> String.replace("-", "_") |> String.to_atom()
          Map.put(acc, key, value)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp find_positional(args) do
    Enum.find(args, fn arg -> not String.starts_with?(arg, "--") end) ||
      (Fmt.err("Missing required ID argument"); System.halt(1))
  end

  defp ask(prompt) do
    IO.write(prompt <> " ")
    IO.read(:stdio, :line) |> String.trim()
  end

  defp strip_api(url) do
    String.trim_trailing(url, "/api") |> String.trim_trailing("/")
  end

  defp default_expiry do
    Date.add(Date.utc_today(), 365) |> Date.to_iso8601()
  end
end
