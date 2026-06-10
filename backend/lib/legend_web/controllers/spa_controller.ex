defmodule LegendWeb.SPAController do
  use LegendWeb, :controller

  def index(conn, _params) do
    index = Application.app_dir(:legend, "priv/static/index.html")

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index)
    else
      send_resp(conn, 404, "Frontend not built. Run `just build` first.")
    end
  end
end
