defmodule Legend.Tunnels.SpriteProxyTest do
  use ExUnit.Case, async: true

  test "implements the Tunnel behaviour with id sprite_proxy" do
    assert Legend.Tunnels.SpriteProxy.id() == "sprite_proxy"
    assert function_exported?(Legend.Tunnels.SpriteProxy, :open, 1)
    assert function_exported?(Legend.Tunnels.SpriteProxy, :close, 1)
  end
end
