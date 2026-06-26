defmodule LegendWeb.SessionApiTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.{Agents, Devices}
  alias LegendWeb.DeviceToken

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

  test "GET /api/sessions never exposes mcp_token", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{
        harness_id: "claude_code",
        runtime_id: "test",
        cwd: "/tmp"
      })

    conn = get(conn, "/api/sessions")
    body = response(conn, 200)

    refute body =~ "mcp_token"
    refute body =~ session.mcp_token
  end

  test "DELETE /api/sessions/:id destroys", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})

    conn = delete(conn, "/api/sessions/#{session.id}")
    assert response(conn, 200)
    assert {:error, _} = Legend.Core.Agents.get_session(session.id)
  end

  test "PATCH /api/sessions/:id/resume resumes an interrupted session", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{
        harness_id: "claude_code",
        runtime_id: "test",
        cwd: "/tmp"
      })

    Legend.Core.Agents.SessionServer.ensure_stopped(session.id)
    Legend.Core.Agents.interrupt_session!(Legend.Core.Agents.get_session!(session.id))

    response =
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> patch(
        "/api/sessions/#{session.id}/resume",
        Jason.encode!(%{data: %{type: "session", id: session.id, attributes: %{}}})
      )
      |> json_response(200)

    assert response["data"]["attributes"]["status"] == "running"
  end

  test "PATCH /api/sessions/:id/resume on a running session is rejected", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{
        harness_id: "claude_code",
        runtime_id: "test",
        cwd: "/tmp"
      })

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> patch(
        "/api/sessions/#{session.id}/resume",
        Jason.encode!(%{data: %{type: "session", id: session.id, attributes: %{}}})
      )

    assert conn.status == 400
  end

  test "a remote device's DELETE is audited, attributing the device", %{conn: conn} do
    session = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> delete("/api/sessions/#{session.id}")

    assert response(conn, 200)

    rows = Enum.filter(Devices.list_audit!(), &(&1.action == "delete"))
    assert [%{device_id: device_id, session_id: session_id}] = rows
    assert device_id == device.id
    assert session_id == session.id
  end

  test "a loopback DELETE writes no audit row (remote-only)", %{conn: conn} do
    session = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})

    # ConnCase conns are loopback ({127,0,0,1}) by default => no device actor.
    conn = delete(conn, "/api/sessions/#{session.id}")
    assert response(conn, 200)

    rows =
      Devices.list_audit!()
      |> Enum.filter(&(&1.action == "delete" and &1.session_id == session.id))

    assert rows == []
  end

  test "a remote device's resume is audited, attributing the device", %{conn: conn} do
    session =
      Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    Agents.SessionServer.ensure_stopped(session.id)
    Agents.interrupt_session!(Agents.get_session!(session.id))

    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    %{conn | remote_ip: {100, 64, 1, 2}}
    |> put_req_header("authorization", "Bearer " <> token)
    |> patch(
      "/api/sessions/#{session.id}/resume",
      Jason.encode!(%{data: %{type: "session", id: session.id, attributes: %{}}})
    )
    |> json_response(200)

    rows = Enum.filter(Devices.list_audit!(), &(&1.action == "resume"))
    assert [%{device_id: device_id, session_id: session_id}] = rows
    assert device_id == device.id
    assert session_id == session.id
  end
end
