defmodule LegendWeb.MCPController do
  @moduledoc """
  Minimal MCP server over streamable HTTP (plain-JSON responses, no SSE): the
  agent-facing twin of the JSON:API surface. Hand-rolled — the protocol surface
  Legend needs is five JSON-RPC methods. Auth: per-session bearer token, which
  also identifies the calling session (agents never assert their own identity).
  """

  use LegendWeb, :controller

  alias Legend.Core.Agents
  alias Legend.Core.Library
  alias Legend.Core.Signals.Tools

  @tool_providers [Tools, Library.Tools]

  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @default_protocol_version "2025-03-26"

  plug :authenticate

  # Requests without an id are JSON-RPC notifications: accept and discard.
  def handle(conn, %{"method" => _} = params) when not is_map_key(params, "id") do
    send_resp(conn, 202, "")
  end

  def handle(conn, %{"method" => method, "id" => id} = params) do
    json(
      conn,
      rpc_response(id, dispatch(method, params["params"] || %{}, conn.assigns.mcp_session))
    )
  end

  def handle(conn, _params) do
    json(conn, rpc_response(nil, {:error, %{code: -32600, message: "invalid request"}}))
  end

  defp dispatch("initialize", params, _session) do
    version =
      if params["protocolVersion"] in @protocol_versions,
        do: params["protocolVersion"],
        else: @default_protocol_version

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "legend", version: to_string(Application.spec(:legend, :vsn))}
     }}
  end

  defp dispatch("ping", _params, _session), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _session) do
    {:ok, %{tools: Enum.flat_map(@tool_providers, & &1.list())}}
  end

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    args = params["arguments"] || %{}

    result =
      case provider_for(name) do
        Legend.Core.Signals.Tools -> Tools.dispatch(session, name, args)
        Legend.Core.Library.Tools -> Library.Tools.dispatch(name, args)
        nil -> {:error, "unknown tool: #{name}"}
      end

    case result do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: false}}
      {:error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}}
    end
  end

  defp dispatch(method, _params, _session) do
    {:error, %{code: -32601, message: "method not found: #{method}"}}
  end

  defp provider_for(name) do
    Enum.find(@tool_providers, fn mod -> Enum.any?(mod.list(), &(&1.name == name)) end)
  end

  defp rpc_response(id, {:ok, result}), do: %{jsonrpc: "2.0", id: id, result: result}
  defp rpc_response(id, {:error, error}), do: %{jsonrpc: "2.0", id: id, error: error}

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
