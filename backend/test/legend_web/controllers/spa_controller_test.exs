defmodule LegendWeb.SPAControllerTest do
  use LegendWeb.ConnCase, async: false

  setup do
    static_dir = Application.app_dir(:legend, "priv/static")
    index = Path.join(static_dir, "index.html")
    File.mkdir_p!(static_dir)
    File.write!(index, "<html><body>legend spa</body></html>")
    on_exit(fn -> File.rm(index) end)
    :ok
  end

  test "GET / serves the SPA index", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "legend spa"
  end

  test "unknown paths fall back to the SPA index", %{conn: conn} do
    conn = get(conn, "/some/client/route")
    assert html_response(conn, 200) =~ "legend spa"
  end
end
