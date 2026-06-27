defmodule LegendWeb.ViaRelay do
  @moduledoc """
  Marks a connection as arriving through the relay ingress. A `via_relay`
  connection is ALWAYS treated as non-loopback by the trust choke points
  (`DeviceAuth`, `LoopbackOnly`, `UserSocket`) — even though the relay splice
  dials `127.0.0.1`, so a device token is required and loopback-only management
  is rejected. The main endpoint never stamps this, so its behavior is unchanged.
  """
  @key :via_relay

  @doc "True when an HTTP conn was stamped by the relay ingress."
  def conn?(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, @key) == true

  @doc "True when socket `connect_info` carries the relay marker."
  def info?(%{via_relay: true}), do: true
  def info?(_), do: false

  @doc "Stamp an HTTP conn as via-relay (used by the ingress endpoint head plug)."
  def stamp(%Plug.Conn{} = conn), do: Plug.Conn.assign(conn, @key, true)
end
