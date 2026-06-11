defmodule LegendWeb.LibraryControllerTest do
  use LegendWeb.ConnCase, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:legend, :library_path)
    Application.put_env(:legend, :library_path, tmp)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "PUT then GET file round-trips, creating parents", %{conn: conn} do
    conn1 = put(conn, "/api/library/file", %{path: "skills/new/tip.md", content: "# Tip"})
    assert json_response(conn1, 200)

    conn2 = get(conn, "/api/library/file", path: "skills/new/tip.md")

    assert %{"data" => %{"path" => "skills/new/tip.md", "content" => "# Tip"}} =
             json_response(conn2, 200)
  end

  test "tree lists entries with metadata", %{conn: conn} do
    put(conn, "/api/library/file", %{path: "knowledge/a.md", content: "x"})
    conn = get(conn, "/api/library/tree")

    assert %{"data" => entries} = json_response(conn, 200)
    file = Enum.find(entries, &(&1["path"] == "knowledge/a.md"))
    assert file["type"] == "file"
    assert is_integer(file["size"])
    assert is_binary(file["mtime"])
  end

  test "DELETE removes a file", %{conn: conn} do
    put(conn, "/api/library/file", %{path: "artifacts/x.txt", content: "x"})
    conn1 = delete(conn, "/api/library/file", path: "artifacts/x.txt")
    assert json_response(conn1, 200)

    conn2 = get(conn, "/api/library/file", path: "artifacts/x.txt")
    assert json_response(conn2, 404)
  end

  test "traversal and invalid paths are rejected with 400", %{conn: conn} do
    for bad <- ["../secrets.txt", "/etc/passwd", "a/../../b", "~/escape.txt"] do
      assert json_response(get(conn, "/api/library/file", path: bad), 400)
      assert json_response(put(conn, "/api/library/file", %{path: bad, content: "x"}), 400)
      assert json_response(delete(conn, "/api/library/file", path: bad), 400)
    end
  end

  test "null bytes in paths map to 400, not 500", %{conn: conn} do
    assert json_response(get(conn, "/api/library/file", path: <<?a, 0, ?b>>), 400)
  end

  test "missing file is 404; binary file is 415", %{conn: conn, tmp_dir: tmp} do
    assert json_response(get(conn, "/api/library/file", path: "nope.md"), 404)

    File.write!(Path.join(tmp, "blob.bin"), <<0xFF, 0xFE, 0x00>>)
    assert json_response(get(conn, "/api/library/file", path: "blob.bin"), 415)
  end
end
