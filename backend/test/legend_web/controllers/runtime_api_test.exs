defmodule LegendWeb.RuntimeApiTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/runtimes lists registered runtimes with capabilities", %{conn: conn} do
    body = conn |> get("/api/runtimes") |> json_response(200)
    ids = Enum.map(body["data"], & &1["id"])
    assert "local_pty" in ids

    local = Enum.find(body["data"], &(&1["id"] == "local_pty"))
    assert local["capabilities"]["library"] == "path"
    assert local["capabilities"]["provisions?"] == false
  end
end
