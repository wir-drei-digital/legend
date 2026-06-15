defmodule LegendWeb.TunnelPlugTest do
  use Legend.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    {:ok, a} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    {:ok, b} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    %{a: Agents.get_session!(a.id), b: Agents.get_session!(b.id)}
  end

  defp call(conn, bound_session_id) do
    LegendWeb.TunnelPlug.call(conn, LegendWeb.TunnelPlug.init(bound_session_id: bound_session_id))
  end

  defp mcp_conn(token, body) do
    conn(:post, "/api/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(token)
  end

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "the bound session's token reaches MCP", %{a: a} do
    conn = call(mcp_conn(a.mcp_token, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 200
    assert %{"result" => %{"tools" => _}} = Jason.decode!(conn.resp_body)
  end

  test "a token for a different session is rejected with 403", %{a: a, b: b} do
    conn = call(mcp_conn(b.mcp_token, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 403
  end

  test "a missing token is rejected with 401", %{a: a} do
    conn = call(mcp_conn(nil, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 401
  end

  test "health needs no token", %{a: a} do
    conn = call(conn(:get, "/api/health"), a.id)
    assert conn.status == 200 and conn.resp_body == "ok"
  end

  test "non-MCP routes are not mounted (404)", %{a: a} do
    for path <- ["/api/sessions", "/api/settings/library-path", "/api/library/file"] do
      conn =
        call(conn(:get, path) |> put_req_header("authorization", "Bearer #{a.mcp_token}"), a.id)

      assert conn.status == 404, "#{path} should not be reachable through the tunnel"
    end
  end
end
