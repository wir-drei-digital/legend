defmodule Legend.Tunnels.SpriteProxyTest do
  use ExUnit.Case, async: true

  test "implements the Tunnel behaviour with id sprite_proxy" do
    assert Legend.Tunnels.SpriteProxy.id() == "sprite_proxy"
    assert function_exported?(Legend.Tunnels.SpriteProxy, :open, 1)
    assert function_exported?(Legend.Tunnels.SpriteProxy, :close, 1)
  end

  test "close/1 stops both processes in the handle and is idempotent" do
    alias Legend.Tunnels.SpriteProxy.Server

    {:ok, server} = Server.start_link(target_port: 1)
    {:ok, carrier} = Server.start_link(target_port: 1)

    assert :ok = Legend.Tunnels.SpriteProxy.close(%{carrier: carrier, server: server})
    refute Process.alive?(server)
    refute Process.alive?(carrier)

    # idempotent / race-safe: closing again with dead pids must not raise
    assert :ok = Legend.Tunnels.SpriteProxy.close(%{carrier: carrier, server: server})
  end
end
