defmodule LicenseAPI.Plugs.Authenticate do
  @moduledoc """
  Plug that verifies bearer tokens against stored hashes.
  Assigns `:api_token` to the conn on success.
  """
  import Plug.Conn
  alias LicenseAPI.{Repo}
  alias LicenseAPI.Schemas.ApiToken
  import Ecto.Query

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer(conn),
         {:ok, api_token} <- verify_token(token) do
      assign(conn, :api_token, api_token)
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: to_string(reason)}))
        |> halt()
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_authorization}
    end
  end

  defp verify_token(plaintext) do
    # Get the prefix to narrow the search
    prefix = String.slice(plaintext, 0, 12)

    candidates =
      ApiToken
      |> where(token_prefix: ^prefix, active: true)
      |> Repo.all()

    case Enum.find(candidates, fn t -> Bcrypt.verify_pass(plaintext, t.token_hash) end) do
      nil ->
        # Constant-time dummy check to prevent timing attacks
        Bcrypt.no_user_verify()
        {:error, :invalid_token}

      token ->
        {:ok, token}
    end
  end
end
