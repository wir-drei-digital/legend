defmodule LegendWeb.RelayIngressEndpoint do
  @moduledoc """
  A dedicated Phoenix endpoint for relay-routed traffic. The Part-2 federation
  carrier splices each relay stream to this endpoint's loopback port. Because the
  splice dials 127.0.0.1, this endpoint STAMPS every connection `via_relay` so the
  trust choke points never grant loopback trust — a device token is required and
  loopback-only management 403s. `/api/mcp` is not exposed (agent-only surface).
  Mounts static + router + socket (all of which live at the endpoint layer).

  Mirrors `LegendWeb.Endpoint`'s socket/static/plug stack with two deliberate
  differences: no cookie session / Corsica (CORS for the relay host is deferred to
  Part 2 via `check_origin`), and a `:relay_guards` plug runs just before the
  router to drop `/api/mcp` and stamp `via_relay`.
  """
  use Phoenix.Endpoint, otp_app: :legend

  socket "/socket", LegendWeb.UserSocket,
    websocket: [connect_info: [:peer_data, via_relay: true]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :legend,
    gzip: not code_reloading?,
    only: LegendWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug AshPhoenix.Plug.CheckCodegenStatus
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :legend
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, AshJsonApi.Plug.Parser],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug :relay_guards

  plug LegendWeb.Router

  # Drop the agent MCP surface on the public relay ingress, and stamp every other
  # connection via_relay (=> never loopback-trusted downstream).
  def relay_guards(%Plug.Conn{path_info: ["api", "mcp" | _]} = conn, _opts) do
    conn
    |> Plug.Conn.put_status(404)
    |> Phoenix.Controller.json(%{error: "not found"})
    |> Plug.Conn.halt()
  end

  def relay_guards(conn, _opts), do: LegendWeb.ViaRelay.stamp(conn)
end
