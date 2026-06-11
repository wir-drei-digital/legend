defmodule LegendWeb.SessionApiTest do
  use LegendWeb.ConnCase, async: false

  @jsonapi "application/vnd.api+json"

  setup %{conn: conn} do
    Legend.Runtimes.Test.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    conn =
      conn
      |> put_req_header("accept", @jsonapi)
      |> put_req_header("content-type", @jsonapi)

    %{conn: conn}
  end

  test "POST /api/sessions creates and starts a session", %{conn: conn} do
    body = %{
      data: %{
        type: "session",
        attributes: %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}
      }
    }

    conn = post(conn, "/api/sessions", Jason.encode!(body))

    assert %{"data" => %{"id" => id, "attributes" => attrs}} = json_response(conn, 201)
    assert attrs["status"] == "running"
    assert attrs["harness_id"] == "claude_code"
    assert_receive {:test_runtime, :start, _spec, _opts}
    assert Legend.Core.Agents.SessionServer.whereis(id)
  end

  test "POST with unknown harness returns errors", %{conn: conn} do
    body = %{data: %{type: "session", attributes: %{harness_id: "nope", runtime_id: "test"}}}
    conn = post(conn, "/api/sessions", Jason.encode!(body))
    assert %{"errors" => [_ | _]} = json_response(conn, 400)
  end

  test "GET /api/sessions lists sessions", %{conn: conn} do
    Legend.Core.Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    conn = get(conn, "/api/sessions")

    assert %{"data" => [%{"attributes" => %{"harness_id" => "hermes"}} | _]} =
             json_response(conn, 200)
  end

  test "DELETE /api/sessions/:id destroys", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})

    conn = delete(conn, "/api/sessions/#{session.id}")
    assert response(conn, 200)
    assert {:error, _} = Legend.Core.Agents.get_session(session.id)
  end
end
