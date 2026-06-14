defmodule LegendWeb.MCPLibraryTest do
  use LegendWeb.ConnCase, async: false
  alias Legend.Core.Agents

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-lib-#{System.unique_integer([:positive])}")
    Application.put_env(:legend, :library_default_root, root)
    Legend.Core.Library.ensure_seeded!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:legend, :library_default_root)
    end)

    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    {:ok, token: session.mcp_token}
  end

  defp rpc(conn, token, method, params) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  test "tools/list includes both signal and library tools", %{conn: conn, token: token} do
    names = rpc(conn, token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    assert "send_message" in names
    assert "library_write" in names and "library_read" in names
  end

  test "library_write then library_read round-trips via MCP", %{conn: conn, token: token} do
    w =
      rpc(conn, token, "tools/call", %{
        "name" => "library_write",
        "arguments" => %{"path" => "knowledge/m.md", "content" => "tunneled"}
      })

    refute w["result"]["isError"]

    r =
      rpc(conn, token, "tools/call", %{
        "name" => "library_read",
        "arguments" => %{"path" => "knowledge/m.md"}
      })

    assert hd(r["result"]["content"])["text"] == "tunneled"
  end

  test "a signal tool still works through the composed dispatch", %{conn: conn, token: token} do
    r = rpc(conn, token, "tools/call", %{"name" => "list_agents", "arguments" => %{}})
    refute r["result"]["isError"]
  end
end
