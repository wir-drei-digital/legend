defmodule LegendWeb.PairController do
  @moduledoc """
  Stub placeholder — fleshed out in Task 6 (pairing redeem endpoint). Exists so
  the router's compile-time controller checks pass while the route is wired.
  """
  use LegendWeb, :controller

  def redeem(conn, _params) do
    conn
    |> put_status(501)
    |> json(%{error: "not_implemented"})
  end
end
