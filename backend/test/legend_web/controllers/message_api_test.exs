defmodule LegendWeb.MessageApiTest do
  use LegendWeb.ConnCase, async: false

  @jsonapi "application/vnd.api+json"

  setup %{conn: conn} do
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

  defp start_session! do
    Legend.Core.Agents.start_session!(%{
      harness_id: "claude_code",
      runtime_id: "test",
      cwd: "/tmp"
    })
  end

  test "GET /api/messages lists messages", %{conn: conn} do
    session = start_session!()
    Legend.Core.Signals.send_message!(%{to_session_id: session.id, payload: "hi"})

    conn = get(conn, "/api/messages")

    assert %{"data" => [_ | _] = data} = json_response(conn, 200)
    assert Enum.any?(data, &(&1["attributes"]["payload"] == "hi"))
  end

  test "POST /api/messages sends a human message", %{conn: conn} do
    session = start_session!()

    body = %{
      data: %{
        type: "message",
        attributes: %{to_session_id: session.id, payload: "hi"}
      }
    }

    conn = post(conn, "/api/messages", Jason.encode!(body))

    assert %{"data" => %{"attributes" => attrs}} = json_response(conn, 201)
    assert attrs["kind"] == "message"
    assert attrs["payload"] == "hi"
    assert attrs["to_session_id"] == session.id
    assert is_nil(attrs["from_session_id"])
    assert is_nil(attrs["read_at"])
  end

  test "POST /api/messages rejects forged extra attributes", %{conn: conn} do
    session = start_session!()

    body = %{
      data: %{
        type: "message",
        attributes: %{
          to_session_id: session.id,
          payload: "hi",
          kind: "system",
          from_session_id: Ash.UUID.generate(),
          read_at: DateTime.utc_now()
        }
      }
    }

    conn = post(conn, "/api/messages", Jason.encode!(body))

    assert json_response(conn, 400)
    assert %{"errors" => [_ | _]} = json_response(conn, 400)
  end

  test "POST /api/messages with unknown to_session_id is rejected", %{conn: conn} do
    body = %{
      data: %{
        type: "message",
        attributes: %{to_session_id: Ash.UUID.generate(), payload: "hi"}
      }
    }

    conn = post(conn, "/api/messages", Jason.encode!(body))

    assert %{"errors" => [_ | _]} = json_response(conn, 400)
  end
end
