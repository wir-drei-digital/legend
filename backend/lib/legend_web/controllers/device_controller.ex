defmodule LegendWeb.DeviceController do
  @moduledoc """
  Stub placeholder — fleshed out in Task 6 (device list / pair-code / revoke).
  Exists so the router's compile-time controller checks pass while the routes
  are wired.
  """
  use LegendWeb, :controller

  def index(conn, _params), do: not_implemented(conn)
  def create_pair_code(conn, _params), do: not_implemented(conn)
  def revoke(conn, _params), do: not_implemented(conn)

  defp not_implemented(conn) do
    conn
    |> put_status(501)
    |> json(%{error: "not_implemented"})
  end
end
