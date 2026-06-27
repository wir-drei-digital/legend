defmodule LegendWeb.ViaRelayTest do
  use ExUnit.Case, async: true
  alias LegendWeb.ViaRelay

  test "stamp marks a conn; conn? reads it" do
    conn = %Plug.Conn{} |> ViaRelay.stamp()
    assert ViaRelay.conn?(conn)
    refute ViaRelay.conn?(%Plug.Conn{})
  end

  test "info? reads the connect_info map" do
    assert ViaRelay.info?(%{via_relay: true})
    refute ViaRelay.info?(%{peer_data: %{address: {127, 0, 0, 1}}})
    refute ViaRelay.info?(%{})
  end
end
