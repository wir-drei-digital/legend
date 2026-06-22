defmodule LegendWeb.HarnessControllerTest do
  use LegendWeb.ConnCase, async: false

  test "GET /api/harnesses lists registered harness definitions", %{conn: conn} do
    conn = get(conn, "/api/harnesses")

    assert %{"data" => harnesses} = json_response(conn, 200)
    ids = Enum.map(harnesses, & &1["id"]) |> Enum.sort()
    assert ids == ["claude_code", "codex", "gemini", "hermes"]

    claude = Enum.find(harnesses, &(&1["id"] == "claude_code"))
    assert claude["name"] == "Claude Code"
    assert claude["transports"] == ["acp", "terminal"]

    hermes = Enum.find(harnesses, &(&1["id"] == "hermes"))
    assert hermes["transports"] == ["terminal"]
  end

  test "harness payload includes resumable", %{conn: conn} do
    data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]
    claude = Enum.find(data, &(&1["id"] == "claude_code"))
    hermes = Enum.find(data, &(&1["id"] == "hermes"))
    assert claude["resumable"] == true
    assert hermes["resumable"] == false
  end

  test "GET /api/harnesses reports provisionable per harness", %{conn: conn} do
    data = conn |> get("/api/harnesses") |> json_response(200) |> Map.fetch!("data")
    by_id = Map.new(data, &{&1["id"], &1})

    assert Map.has_key?(by_id, "claude_code")
    assert by_id["claude_code"]["provisionable"] == true
    # Every harness carries the boolean.
    assert Enum.all?(data, &is_boolean(&1["provisionable"]))
  end

  describe "setup" do
    setup do
      home =
        Path.join(System.tmp_dir!(), "legend-hermes-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(home)
      previous = Application.get_env(:legend, :hermes_home)
      Application.put_env(:legend, :hermes_home, home)

      on_exit(fn ->
        Application.put_env(:legend, :hermes_home, previous)
        File.rm_rf!(home)
      end)

      %{home: home}
    end

    test "GET /api/harnesses carries the setup object", %{conn: conn} do
      data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]

      hermes = Enum.find(data, &(&1["id"] == "hermes"))
      assert hermes["setup"]["status"] == "missing"
      assert hermes["setup"]["summary"] =~ "config.yaml"
      assert hermes["setup"]["restart_hint"] == true

      claude = Enum.find(data, &(&1["id"] == "claude_code"))
      assert claude["setup"]["status"] == "not_applicable"
    end

    test "POST /api/harnesses/hermes/setup applies and returns fresh status", %{
      conn: conn,
      home: home
    } do
      conn = post(conn, ~p"/api/harnesses/hermes/setup")
      assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)
      assert File.exists?(Path.join(home, "config.yaml"))

      data = json_response(get(build_conn(), ~p"/api/harnesses"), 200)["data"]
      hermes = Enum.find(data, &(&1["id"] == "hermes"))
      assert hermes["setup"]["status"] == "ok"
    end

    test "POST for an unknown harness is 404", %{conn: conn} do
      conn = post(conn, ~p"/api/harnesses/nope/setup")
      assert %{"error" => _} = json_response(conn, 404)
    end

    test "POST for a harness without setup is 422", %{conn: conn} do
      conn = post(conn, ~p"/api/harnesses/claude_code/setup")
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "POST surfaces apply failure as 422", %{conn: conn, home: home} do
      File.write!(Path.join(home, "config.yaml"), "mcp_servers: \"not a mapping\"")
      conn = post(conn, ~p"/api/harnesses/hermes/setup")
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "mapping"
    end
  end
end
