defmodule LegendWeb.TunnelPlug do
  @moduledoc """
  The entire HTTP surface a cloud sandbox can reach over its reverse tunnel:
  `POST /api/mcp` (authenticated + bound to one session) and an unauthenticated
  `GET /api/health` connectivity probe. Nothing else is mounted — the main
  Phoenix endpoint is unreachable through any tunnel. Bandit starts one of these
  per cloud session as `{LegendWeb.TunnelPlug, bound_session_id: id}`.
  """

  use Plug.Router

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :match
  plug :dispatch

  # Inject the per-listener bound session id (from Bandit's plug opts) into assigns
  # before the route pipeline runs.
  def call(conn, opts) do
    super(assign(conn, :bound_session_id, Keyword.fetch!(opts, :bound_session_id)), opts)
  end

  get "/api/health" do
    send_resp(conn, 200, "ok")
  end

  post "/api/mcp" do
    case LegendWeb.TunnelAuth.authenticate(conn, conn.assigns.bound_session_id) do
      {:ok, conn, session} ->
        case Legend.Core.MCP.handle(session, conn.body_params) do
          :accepted ->
            send_resp(conn, 202, "")

          {:ok, response} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))
        end

      {:error, conn} ->
        conn
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
