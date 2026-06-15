defmodule LegendWeb.MCPController do
  @moduledoc """
  MCP over streamable HTTP for **local** sessions on the main endpoint. Auth is
  the per-session bearer token, which also identifies the caller. Cloud sessions
  reach MCP through `LegendWeb.TunnelPlug` instead; both share `Legend.Core.MCP`.
  """

  use LegendWeb, :controller

  alias Legend.Core.Agents
  alias Legend.Core.MCP

  plug :authenticate

  def handle(conn, params) do
    case MCP.handle(conn.assigns.mcp_session, params) do
      :accepted -> send_resp(conn, 202, "")
      {:ok, response} -> json(conn, response)
    end
  end

  defp authenticate(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token when token != "" <- token,
         {:ok, session} <- Agents.get_session_by_token(token) do
      assign(conn, :mcp_session, session)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid or missing token"})
        |> halt()
    end
  end
end
