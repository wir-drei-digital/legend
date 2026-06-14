defmodule Legend.Tunnels.SpriteProxyTest do
  use ExUnit.Case, async: true

  test "implements the Tunnel behaviour with id sprite_proxy" do
    assert Legend.Tunnels.SpriteProxy.id() == "sprite_proxy"
    assert function_exported?(Legend.Tunnels.SpriteProxy, :open, 1)
    assert function_exported?(Legend.Tunnels.SpriteProxy, :close, 1)
  end

  test "close/1 stops the server (and its carrier) and is idempotent" do
    alias Legend.Tunnels.SpriteProxy.Server

    noop = fn _s, _p, _srv -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end

    {:ok, server} =
      Server.start_link(target_port: 1, sprite: "x", control_port: 9000, connector: noop)

    assert :ok = Legend.Tunnels.SpriteProxy.close(%{server: server})
    refute Process.alive?(server)

    # idempotent / race-safe: closing again with a dead pid must not raise
    assert :ok = Legend.Tunnels.SpriteProxy.close(%{server: server})
  end
end
