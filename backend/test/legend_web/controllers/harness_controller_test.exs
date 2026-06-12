defmodule LegendWeb.HarnessControllerTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/harnesses lists registered harness definitions", %{conn: conn} do
    conn = get(conn, "/api/harnesses")

    assert %{"data" => harnesses} = json_response(conn, 200)
    ids = Enum.map(harnesses, & &1["id"]) |> Enum.sort()
    assert ids == ["claude_code", "hermes"]

    claude = Enum.find(harnesses, &(&1["id"] == "claude_code"))
    assert claude["name"] == "Claude Code"
    assert claude["kind"] == "terminal"
  end

  test "harness payload includes resumable", %{conn: conn} do
    data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]
    claude = Enum.find(data, &(&1["id"] == "claude_code"))
    hermes = Enum.find(data, &(&1["id"] == "hermes"))
    assert claude["resumable"] == true
    assert hermes["resumable"] == false
  end
end
