defmodule Legend.Core.MCP do
  @moduledoc """
  Transport-agnostic MCP JSON-RPC handling — the agent-facing twin of the
  JSON:API surface. Shared by `LegendWeb.MCPController` (main endpoint, local
  sessions) and `LegendWeb.TunnelPlug` (per-session tunnel listener, cloud
  sessions). The caller session is resolved by each web layer's auth; this
  module never authenticates.
  """

  alias Legend.Core.Library
  alias Legend.Core.Signals.Tools

  @tool_providers [Tools, Library.Tools]
  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @default_protocol_version "2025-03-26"

  @doc "Tool definitions across all providers."
  def tools, do: Enum.flat_map(@tool_providers, & &1.list())

  @doc """
  Handle a decoded JSON-RPC request for `session`. Returns `:accepted` for an
  id-less notification (the web layer replies 202) or `{:ok, response_map}` for
  a request (the web layer replies 200 JSON).
  """
  @spec handle(map(), map()) :: :accepted | {:ok, map()}
  def handle(_session, %{"method" => _} = params) when not is_map_key(params, "id"),
    do: :accepted

  def handle(session, %{"method" => method, "id" => id} = params) do
    {:ok, rpc_response(id, dispatch(method, params["params"] || %{}, session))}
  end

  def handle(_session, _params) do
    {:ok, rpc_response(nil, {:error, %{code: -32600, message: "invalid request"}})}
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

  defp dispatch("tools/list", _params, _session), do: {:ok, %{tools: tools()}}

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    args = params["arguments"] || %{}

    result =
      case provider_for(name) do
        Tools -> Tools.dispatch(session, name, args)
        Library.Tools -> Library.Tools.dispatch(name, args)
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
end
