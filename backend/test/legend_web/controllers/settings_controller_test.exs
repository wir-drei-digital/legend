defmodule LegendWeb.SettingsControllerTest do
  use LegendWeb.ConnCase, async: false

  @moduletag :tmp_dir

  # The global test config sets :library_path (the env-override slot); these
  # tests manage it explicitly per scenario.
  setup do
    original = Application.get_env(:legend, :library_path)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  defp clear_env_override, do: Application.put_env(:legend, :library_path, nil)

  test "GET reports the default with its resolved path when nothing is configured", %{conn: conn} do
    clear_env_override()
    conn = get(conn, "/api/settings/library-path")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["source"] == "default"
    assert data["value"] == nil
    assert data["effective"] == data["default"]
    assert String.ends_with?(data["default"], "test-library-default")
  end

  test "GET reports the env override as source env", %{conn: conn} do
    conn = get(conn, "/api/settings/library-path")
    assert %{"data" => %{"source" => "env"}} = json_response(conn, 200)
  end

  test "PUT validates, seeds, persists, and reports the new state", %{conn: conn, tmp_dir: tmp} do
    clear_env_override()
    target = Path.join(tmp, "lib-root")
    conn1 = put(conn, "/api/settings/library-path", %{path: target})

    assert %{"data" => %{"source" => "setting", "effective" => ^target, "value" => ^target}} =
             json_response(conn1, 200)

    assert File.dir?(Path.join(target, "skills"))
    assert Legend.Core.Settings.get_setting("library_path") == target
  end

  test "PUT rejects an unusable path with 400 and persists nothing", %{conn: conn} do
    clear_env_override()
    conn = put(conn, "/api/settings/library-path", %{path: "/dev/null/nope"})
    assert %{"error" => msg} = json_response(conn, 400)
    assert msg =~ "unusable"
    assert Legend.Core.Settings.get_setting("library_path") == nil
  end

  test "PUT and DELETE refuse with 409 while the env override is active", %{
    conn: conn,
    tmp_dir: tmp
  } do
    assert json_response(put(conn, "/api/settings/library-path", %{path: tmp}), 409)
    assert json_response(delete(conn, "/api/settings/library-path"), 409)
  end

  test "PUT without path gets the uniform error envelope", %{conn: conn} do
    clear_env_override()
    assert %{"error" => _} = json_response(put(conn, "/api/settings/library-path", %{}), 400)
  end

  test "DELETE reverts to the default and reseeds it", %{conn: conn, tmp_dir: tmp} do
    clear_env_override()
    put(conn, "/api/settings/library-path", %{path: Path.join(tmp, "lib-root")})

    conn1 = delete(conn, "/api/settings/library-path")
    assert %{"data" => %{"source" => "default", "value" => nil}} = json_response(conn1, 200)
    assert Legend.Core.Settings.get_setting("library_path") == nil
    assert File.dir?(Path.join(Legend.Core.Library.default_root(), "knowledge"))
  end
end
