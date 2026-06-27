defmodule Relay.CarrierPlug do
  @moduledoc "Upgrades GET /carrier to the Relay.Carrier WebSock handler."
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/carrier"} = conn, _opts) do
    conn |> WebSockAdapter.upgrade(Relay.Carrier, [], timeout: 60_000) |> halt()
  end

  def call(conn, _opts),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
end
