defmodule LegendWeb.TunnelAuth do
  @moduledoc """
  Boundary auth for the per-session tunnel listener. Rejects any request without
  a valid bearer token (401), then enforces that the token resolves to the *one*
  session this tunnel was opened for (403) — so a leaked token is useless except
  through its own tunnel.
  """

  import Plug.Conn
  alias Legend.Core.Agents

  @spec authenticate(Plug.Conn.t(), String.t()) ::
          {:ok, Plug.Conn.t(), struct()} | {:error, Plug.Conn.t()}
  def authenticate(conn, bound_session_id) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token when token != "" <- token,
         {:ok, session} <- Agents.get_session_by_token(token) do
      if session.id == bound_session_id do
        {:ok, conn, session}
      else
        {:error, deny(conn, 403, "token not valid for this tunnel")}
      end
    else
      _ -> {:error, deny(conn, 401, "invalid or missing token")}
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
