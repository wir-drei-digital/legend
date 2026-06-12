defmodule LegendWeb.MCPControllerTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals

  setup %{conn: conn} do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> session.mcp_token)
      |> put_req_header("content-type", "application/json")

    %{
      conn: authed,
      raw_conn: put_req_header(conn, "content-type", "application/json"),
      session: session
    }
  end

  defp rpc(conn, method, params \\ nil, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method}
    body = if params, do: Map.put(body, :params, params), else: body
    post(conn, "/api/mcp", Jason.encode!(body))
  end

  test "rejects a missing or bad token", %{raw_conn: raw_conn} do
    conn = rpc(raw_conn, "tools/list")
    assert json_response(conn, 401)

    conn =
      raw_conn
      |> put_req_header("authorization", "Bearer wrong")
      |> rpc("tools/list")

    assert json_response(conn, 401)
  end

  test "initialize returns protocol version and tool capability", %{conn: conn} do
    response = json_response(rpc(conn, "initialize", %{"protocolVersion" => "2025-03-26"}), 200)

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert response["result"]["protocolVersion"] == "2025-03-26"
    assert response["result"]["capabilities"]["tools"] == %{}
    assert response["result"]["serverInfo"]["name"] == "legend"
  end

  test "notifications get 202 with no body", %{conn: conn} do
    conn =
      post(
        conn,
        "/api/mcp",
        Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})
      )

    assert response(conn, 202)
  end

  test "tools/list returns the five tools", %{conn: conn} do
    response = json_response(rpc(conn, "tools/list"), 200)
    names = Enum.map(response["result"]["tools"], & &1["name"])
    assert "send_message" in names
    assert length(names) == 5
  end

  test "tools/call dispatches with the token's session as caller", %{conn: conn, session: session} do
    target = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})

    response =
      json_response(
        rpc(conn, "tools/call", %{
          "name" => "send_message",
          "arguments" => %{"to" => target.id, "content" => "ping"}
        }),
        200
      )

    assert response["result"]["isError"] == false
    assert [content] = response["result"]["content"]
    assert content["type"] == "text"
    assert content["text"] =~ "Delivered"

    assert [%{from_session_id: from, payload: "ping"}] = Signals.unread_messages!(target.id)
    assert from == session.id
  end

  test "tool errors come back as isError, not JSON-RPC errors", %{conn: conn} do
    response =
      json_response(
        rpc(conn, "tools/call", %{
          "name" => "send_message",
          "arguments" => %{"to" => Ash.UUID.generate(), "content" => "x"}
        }),
        200
      )

    assert response["result"]["isError"] == true
  end

  test "unknown method returns -32601", %{conn: conn} do
    response = json_response(rpc(conn, "wat"), 200)
    assert response["error"]["code"] == -32601
  end
end
