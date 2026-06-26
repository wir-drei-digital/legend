defmodule LegendWeb.LoopbackOnly do
  @moduledoc """
  Management/enrollment endpoints (device roster, pairing, revoke, audit,
  remote-access config) are loopback-only: they require physical possession of
  the instance. A valid remote device token authenticates session USE, not
  management. Non-loopback callers get 403.
  """
  import Plug.Conn

  alias LegendWeb.RemotePeer

  def init(opts), do: opts

  def call(conn, _opts) do
    if RemotePeer.loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{error: "loopback only"})
      |> halt()
    end
  end
end
