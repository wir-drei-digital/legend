defmodule LegendWeb.RemotePeer do
  @moduledoc """
  Loopback predicate shared by the HTTP plug and the socket. Loopback = the
  connection originated on this machine — the trust root. Sound only because no
  localhost-collapsing reverse proxy sits in front (see the spec); the IP is the
  real transport peer, never a forwarded header.
  """

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  @spec loopback?(:inet.ip_address() | nil) :: boolean
  def loopback?(@loopback_v4), do: true
  def loopback?(@loopback_v6), do: true
  # Any 127.0.0.0/8 address is loopback.
  def loopback?({127, _, _, _}), do: true
  def loopback?(_), do: false
end
