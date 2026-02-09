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

  # Activation reporting — no auth (clients don't have admin tokens)
  # The key_hash proves they have a legitimately signed key
  post "/api/activations" do
    case conn.body_params do
      %{"activation" => %{"key_hash" => key_hash, "machine_id" => machine_id} = activation} ->
        machine_info = activation["machine_info"] || %{}
        license_id = find_license_by_hash(key_hash)

        # Upsert: same key + same machine = update timestamp
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
              license_id: license_id
            })
            |> Repo.insert()

          existing ->
            existing
            |> Ecto.Changeset.change(%{ip_address: peer_ip(conn), updated_at: DateTime.utc_now()})
            |> Repo.update()
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "recorded"}))

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
