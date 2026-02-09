defmodule LicenseAPI.Plugs.RequireScope do
  @moduledoc """
  Plug that checks the authenticated token has the required scope.
  Must run after Authenticate.
  """
  import Plug.Conn

  def init(scope) when is_binary(scope), do: scope

  def call(%{assigns: %{api_token: %{scope: scope}}} = conn, required_scope) do
    if scope == "admin" or scope == required_scope do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "insufficient_scope"}))
      |> halt()
    end
  end

  def call(conn, _) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "not_authenticated"}))
    |> halt()
  end
end
