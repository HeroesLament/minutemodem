defmodule LicenseAPI.Router do
  use Plug.Router

  alias LicenseAPI.{Repo}
  alias LicenseAPI.Schemas.{License, Activation}
  import Ecto.Query

  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # Health check — no auth
  get "/health" do
    provisioned = LicenseAPI.KeyStore.provisioned?()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", provisioned: provisioned}))
  end

  # Activation — no auth (clients don't have admin tokens)
  # The key_hash proves they have a legitimately signed key.
  # Server checks seat entitlement, signs and returns an assertion.
  post "/api/activations" do
    case conn.body_params do
      %{"activation" => %{"key_hash" => key_hash, "machine_id" => machine_id} = activation} ->
        machine_info = activation["machine_info"] || %{}
        license_id = find_license_by_hash(key_hash)

        case check_entitlement(key_hash, machine_id, license_id) do
          :ok ->
            # Sign the assertion
            assertion_expires = Date.add(Date.utc_today(), 365)
            payload = "#{key_hash}|#{machine_id}|#{Date.to_iso8601(Date.utc_today())}|#{Date.to_iso8601(assertion_expires)}"

            case LicenseAPI.KeyStore.sign_assertion(payload) do
              {:ok, assertion_string} ->
                # Upsert activation record
                upsert_activation(key_hash, machine_id, machine_info, assertion_string, license_id, conn)

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{assertion: assertion_string, expires: Date.to_iso8601(assertion_expires)}))

              {:error, :not_provisioned} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(503, Jason.encode!(%{error: "server_not_provisioned"}))
            end

          {:error, :seat_limit_exceeded, current, max} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(409, Jason.encode!(%{
              error: "seat_limit_exceeded",
              current_activations: current,
              max_activations: max
            }))

          {:error, :license_not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{error: "denied", reason: "unknown_license"}))

          {:error, :license_inactive} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{error: "denied", reason: "license_inactive"}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "bad_request"}))
    end
  end

  # All other /api routes require authentication
  forward "/api", to: LicenseAPI.Router.API

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp check_entitlement(key_hash, machine_id, license_id) do
    cond do
      is_nil(license_id) ->
        {:error, :license_not_found}

      true ->
        license = Repo.get!(License, license_id)

        if license.status != "active" do
          {:error, :license_inactive}
        else
          # Check if this machine already has an activation (renewal is always OK)
          existing = Repo.get_by(Activation, key_hash: key_hash, machine_id: machine_id)

          if existing do
            # Re-activation of same machine — always allowed
            :ok
          else
            # New machine — check seat limit
            case license.max_activations do
              nil ->
                # Unlimited
                :ok

              max ->
                current =
                  Repo.aggregate(
                    from(a in Activation,
                      where: a.key_hash == ^key_hash and a.status == "active"
                    ),
                    :count
                  )

                if current < max, do: :ok, else: {:error, :seat_limit_exceeded, current, max}
            end
          end
        end
    end
  end

  defp upsert_activation(key_hash, machine_id, machine_info, assertion_string, license_id, conn) do
    case Repo.get_by(Activation, key_hash: key_hash, machine_id: machine_id) do
      nil ->
        %Activation{}
        |> Activation.changeset(%{
          key_hash: key_hash,
          machine_id: machine_id,
          machine_hostname: machine_info["hostname"],
          machine_os: machine_info["os"],
          machine_arch: machine_info["arch"],
          ip_address: peer_ip(conn),
          assertion_string: assertion_string,
          status: "active",
          license_id: license_id
        })
        |> Repo.insert()

      existing ->
        existing
        |> Ecto.Changeset.change(%{
          ip_address: peer_ip(conn),
          assertion_string: assertion_string,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  defp find_license_by_hash(key_hash) do
    Repo.all(from(l in License, select: {l.id, l.key_string}))
    |> Enum.find_value(fn {id, key_string} ->
      computed = :crypto.hash(:sha256, key_string) |> Base.encode16(case: :lower)
      if computed == key_hash, do: id
    end)
  end

  defp peer_ip(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: addr} -> :inet.ntoa(addr) |> to_string()
      _ -> nil
    end
  end
end
