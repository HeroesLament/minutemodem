defmodule LicenseAPI.Router.API do
  use Plug.Router

  alias LicenseAPI.Plugs.{Authenticate, RequireScope}
  alias LicenseAPI.{Repo, KeyStore}
  alias LicenseAPI.Schemas.{License, Activation}
  import Ecto.Query

  plug Authenticate
  plug :match
  plug :dispatch

  # =================================================================
  # License CRUD
  # =================================================================

  @doc """
  Issue a new license.
  POST /api/licenses
  Body: {"email", "tier", "expires", "notes"?}
  Scope: webhook or admin
  """
  post "/licenses" do
    conn = RequireScope.call(conn, "webhook")
    unless conn.halted, do: do_create_license(conn)
  end

  @doc """
  List licenses with optional filters.
  GET /api/licenses?status=active&tier=pro&email=user@example.com
  Scope: admin
  """
  get "/licenses" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      query = from(l in License, order_by: [desc: l.inserted_at])

      query = if s = conn.params["status"], do: where(query, status: ^s), else: query
      query = if t = conn.params["tier"], do: where(query, tier: ^t), else: query
      query = if e = conn.params["email"], do: where(query, email: ^e), else: query

      # Fuzzy search
      query =
        if q = conn.params["q"] do
          pattern = "%#{q}%"
          where(query, [l], like(l.email, ^pattern) or like(l.notes, ^pattern))
        else
          query
        end

      licenses = Repo.all(query)
      json(conn, 200, %{licenses: Enum.map(licenses, &serialize_license/1)})
    end
  end

  @doc """
  Get a specific license with full details including key string.
  GET /api/licenses/:id
  Scope: admin
  """
  get "/licenses/:id" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil -> json(conn, 404, %{error: "not_found"})
        l -> json(conn, 200, %{license: serialize_license(l, include_key: true)})
      end
    end
  end

  # -----------------------------------------------------------------
  # Renewal
  # -----------------------------------------------------------------

  @doc """
  Renew a license — issues a new key with a new expiry, supersedes the old one.
  POST /api/licenses/:id/renew
  Body: {"expires": "YYYY-MM-DD"}
  Scope: admin
  """
  post "/licenses/:id/renew" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        old_license ->
          expires_str = conn.body_params["expires"]

          case expires_str && Date.from_iso8601(expires_str) do
            {:ok, new_expires} ->
              # Issue a new key
              payload =
                LicenseCore.License.to_payload(%LicenseCore.License{
                  email: old_license.email,
                  tier: old_license.tier,
                  expires: new_expires
                })

              case KeyStore.sign(payload) do
                {:ok, key_string} ->
                  # Mark old as superseded
                  Repo.update!(Ecto.Changeset.change(old_license, status: "superseded"))

                  # Create new license
                  {:ok, new_license} =
                    %License{}
                    |> License.changeset(%{
                      email: old_license.email,
                      tier: old_license.tier,
                      expires: new_expires,
                      notes: "Renewed from #{old_license.id}"
                    })
                    |> Ecto.Changeset.put_change(:key_string, key_string)
                    |> Repo.insert()

                  json(conn, 201, %{
                    license: serialize_license(new_license, include_key: true),
                    superseded: old_license.id
                  })

                {:error, :not_provisioned} ->
                  json(conn, 503, %{error: "server_not_provisioned"})
              end

            _ ->
              json(conn, 400, %{error: "bad_request", required: ["expires"]})
          end
      end
    end
  end

  # -----------------------------------------------------------------
  # Tier change
  # -----------------------------------------------------------------

  @doc """
  Change a license tier — issues a new key with the new tier.
  POST /api/licenses/:id/change-tier
  Body: {"tier": "enterprise"}
  Scope: admin
  """
  post "/licenses/:id/change-tier" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        old_license ->
          new_tier = conn.body_params["tier"]

          if new_tier do
            payload =
              LicenseCore.License.to_payload(%LicenseCore.License{
                email: old_license.email,
                tier: new_tier,
                expires: old_license.expires
              })

            case KeyStore.sign(payload) do
              {:ok, key_string} ->
                Repo.update!(Ecto.Changeset.change(old_license, status: "superseded"))

                {:ok, new_license} =
                  %License{}
                  |> License.changeset(%{
                    email: old_license.email,
                    tier: new_tier,
                    expires: old_license.expires,
                    notes: "Tier changed from #{old_license.tier}, prev: #{old_license.id}"
                  })
                  |> Ecto.Changeset.put_change(:key_string, key_string)
                  |> Repo.insert()

                json(conn, 201, %{
                  license: serialize_license(new_license, include_key: true),
                  superseded: old_license.id
                })

              {:error, :not_provisioned} ->
                json(conn, 503, %{error: "server_not_provisioned"})
            end
          else
            json(conn, 400, %{error: "bad_request", required: ["tier"]})
          end
      end
    end
  end

  # -----------------------------------------------------------------
  # Transfer
  # -----------------------------------------------------------------

  @doc """
  Transfer a license to a new email — issues a new key, revokes the old.
  POST /api/licenses/:id/transfer
  Body: {"email": "new@owner.com"}
  Scope: admin
  """
  post "/licenses/:id/transfer" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        old_license ->
          new_email = conn.body_params["email"]

          if new_email do
            payload =
              LicenseCore.License.to_payload(%LicenseCore.License{
                email: new_email,
                tier: old_license.tier,
                expires: old_license.expires
              })

            case KeyStore.sign(payload) do
              {:ok, key_string} ->
                Repo.update!(Ecto.Changeset.change(old_license, status: "transferred"))

                {:ok, new_license} =
                  %License{}
                  |> License.changeset(%{
                    email: new_email,
                    tier: old_license.tier,
                    expires: old_license.expires,
                    notes: "Transferred from #{old_license.email}, prev: #{old_license.id}"
                  })
                  |> Ecto.Changeset.put_change(:key_string, key_string)
                  |> Repo.insert()

                json(conn, 201, %{
                  license: serialize_license(new_license, include_key: true),
                  transferred_from: old_license.id
                })

              {:error, :not_provisioned} ->
                json(conn, 503, %{error: "server_not_provisioned"})
            end
          else
            json(conn, 400, %{error: "bad_request", required: ["email"]})
          end
      end
    end
  end

  # -----------------------------------------------------------------
  # Revoke / Refund
  # -----------------------------------------------------------------

  @doc """
  Revoke a license.
  DELETE /api/licenses/:id
  Scope: admin
  """
  delete "/licenses/:id" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        license ->
          Repo.update!(Ecto.Changeset.change(license, status: "revoked"))

          json(conn, 200, %{
            message: "revoked",
            note: "Client key remains valid offline until #{license.expires}"
          })
      end
    end
  end

  @doc """
  Refund a license (distinct from revoke for accounting).
  POST /api/licenses/:id/refund
  Scope: admin
  """
  post "/licenses/:id/refund" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        license ->
          Repo.update!(Ecto.Changeset.change(license, status: "refunded"))

          json(conn, 200, %{
            message: "refunded",
            note: "Client key remains valid offline until #{license.expires}"
          })
      end
    end
  end

  # -----------------------------------------------------------------
  # Notes
  # -----------------------------------------------------------------

  @doc """
  Add a note to a license.
  POST /api/licenses/:id/notes
  Body: {"note": "Called about activation issue, resolved"}
  Scope: admin
  """
  post "/licenses/:id/notes" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        license ->
          note = conn.body_params["note"] || ""
          existing = license.notes || ""
          timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = if existing == "", do: "[#{timestamp}] #{note}", else: "#{existing}\n[#{timestamp}] #{note}"

          Repo.update!(Ecto.Changeset.change(license, notes: updated))
          json(conn, 200, %{message: "note_added"})
      end
    end
  end

  @doc """
  List activations for a license.
  GET /api/licenses/:id/activations
  Scope: admin
  """
  get "/licenses/:id/activations" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      activations =
        Activation
        |> where(license_id: ^id)
        |> order_by(desc: :updated_at)
        |> Repo.all()

      json(conn, 200, %{
        activations:
          Enum.map(activations, fn a ->
            %{
              id: a.id,
              machine_id: String.slice(a.machine_id, 0, 12) <> "...",
              hostname: a.machine_hostname,
              os: a.machine_os,
              arch: a.machine_arch,
              ip: a.ip_address,
              first_seen: DateTime.to_iso8601(a.inserted_at),
              last_seen: DateTime.to_iso8601(a.updated_at)
            }
          end)
      })
    end
  end

  # =================================================================
  # Bulk operations
  # =================================================================

  @doc """
  Issue multiple licenses at once.
  POST /api/licenses/bulk
  Body: {"licenses": [{"email", "tier", "expires"}, ...]}
  Scope: admin
  """
  post "/licenses/bulk" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case conn.body_params do
        %{"licenses" => items} when is_list(items) ->
          results =
            Enum.map(items, fn item ->
              case item do
                %{"email" => email, "tier" => tier, "expires" => expires_str} ->
                  case Date.from_iso8601(expires_str) do
                    {:ok, expires} ->
                      payload =
                        LicenseCore.License.to_payload(%LicenseCore.License{
                          email: email,
                          tier: tier,
                          expires: expires
                        })

                      case KeyStore.sign(payload) do
                        {:ok, key_string} ->
                          {:ok, license} =
                            %License{}
                            |> License.changeset(%{
                              email: email,
                              tier: tier,
                              expires: expires,
                              notes: item["notes"]
                            })
                            |> Ecto.Changeset.put_change(:key_string, key_string)
                            |> Repo.insert()

                          %{email: email, status: "created", id: license.id, key_string: key_string}

                        {:error, reason} ->
                          %{email: email, status: "error", reason: inspect(reason)}
                      end

                    _ ->
                      %{email: email, status: "error", reason: "invalid_date"}
                  end

                _ ->
                  %{status: "error", reason: "missing_fields"}
              end
            end)

          json(conn, 201, %{results: results})

        _ ->
          json(conn, 400, %{error: "bad_request", required: ["licenses"]})
      end
    end
  end

  # =================================================================
  # Reports
  # =================================================================

  @doc """
  Licenses expiring within N days.
  GET /api/reports/expiring?days=30
  Scope: admin
  """
  get "/reports/expiring" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      days = String.to_integer(conn.params["days"] || "30")
      cutoff = Date.add(Date.utc_today(), days)

      licenses =
        from(l in License,
          where: l.status == "active" and l.expires <= ^cutoff and l.expires >= ^Date.utc_today(),
          order_by: l.expires
        )
        |> Repo.all()

      json(conn, 200, %{
        days: days,
        count: length(licenses),
        licenses: Enum.map(licenses, &serialize_license/1)
      })
    end
  end

  @doc """
  License statistics.
  GET /api/reports/stats
  Scope: admin
  """
  get "/reports/stats" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      by_status =
        from(l in License, group_by: l.status, select: {l.status, count(l.id)})
        |> Repo.all()
        |> Map.new()

      by_tier =
        from(l in License,
          where: l.status == "active",
          group_by: l.tier,
          select: {l.tier, count(l.id)}
        )
        |> Repo.all()
        |> Map.new()

      total_activations = Repo.aggregate(Activation, :count)
      unique_machines = Repo.aggregate(from(a in Activation, select: a.machine_id), :count)

      json(conn, 200, %{
        by_status: by_status,
        by_tier: by_tier,
        activations: %{total: total_activations, unique_machines: unique_machines}
      })
    end
  end

  @doc """
  Export all active licenses as JSON (for backup/accounting).
  GET /api/reports/export?status=active
  Scope: admin
  """
  get "/reports/export" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      status = conn.params["status"] || "active"

      licenses =
        from(l in License, where: l.status == ^status, order_by: l.email)
        |> Repo.all()

      json(conn, 200, %{
        exported_at: DateTime.to_iso8601(DateTime.utc_now()),
        status: status,
        count: length(licenses),
        licenses: Enum.map(licenses, fn l -> serialize_license(l, include_key: true) end)
      })
    end
  end

  # =================================================================
  # Server info
  # =================================================================

  get "/info" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      active_count = Repo.aggregate(from(l in License, where: l.status == "active"), :count)
      total_count = Repo.aggregate(License, :count)

      json(conn, 200, %{
        provisioned: KeyStore.provisioned?(),
        licenses: %{active: active_count, total: total_count}
      })
    end
  end

  # =================================================================
  # .mmlic file generation
  # =================================================================

  @doc """
  Download a license as a .mmlic file.
  GET /api/licenses/:id/download
  Scope: admin
  """
  get "/licenses/:id/download" do
    conn = RequireScope.call(conn, "admin")

    unless conn.halted do
      case Repo.get(License, id) do
        nil ->
          json(conn, 404, %{error: "not_found"})

        license ->
          filename = "#{license.email |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")}.mmlic"

          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> send_resp(200, license.key_string)
      end
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  # =================================================================
  # Helpers
  # =================================================================

  defp do_create_license(conn) do
    with %{"email" => email, "tier" => tier, "expires" => expires_str} <- conn.body_params,
         {:ok, expires} <- Date.from_iso8601(expires_str) do
      notes = conn.body_params["notes"]

      payload =
        LicenseCore.License.to_payload(%LicenseCore.License{
          email: email,
          tier: tier,
          expires: expires
        })

      case KeyStore.sign(payload) do
        {:ok, key_string} ->
          changeset =
            %License{}
            |> License.changeset(%{email: email, tier: tier, expires: expires, notes: notes})
            |> Ecto.Changeset.put_change(:key_string, key_string)

          case Repo.insert(changeset) do
            {:ok, license} ->
              json(conn, 201, %{license: serialize_license(license, include_key: true)})

            {:error, changeset} ->
              json(conn, 422, %{error: "validation_failed", details: format_errors(changeset)})
          end

        {:error, :not_provisioned} ->
          json(conn, 503, %{error: "server_not_provisioned"})
      end
    else
      _ -> json(conn, 400, %{error: "bad_request", required: ~w(email tier expires)})
    end
  end

  defp serialize_license(l, opts \\ []) do
    base = %{
      id: l.id,
      email: l.email,
      tier: l.tier,
      expires: Date.to_iso8601(l.expires),
      status: l.status,
      notes: l.notes,
      issued_at: DateTime.to_iso8601(l.inserted_at)
    }

    if Keyword.get(opts, :include_key, false) do
      Map.put(base, :key_string, l.key_string)
    else
      base
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
