defmodule LegendWeb.HealthController do
  use LegendWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
