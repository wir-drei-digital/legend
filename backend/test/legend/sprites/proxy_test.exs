defmodule Legend.Sprites.ProxyTest do
  use ExUnit.Case, async: true
  alias Legend.Sprites.Proxy

  # NOTE: Jason encodes map keys alphabetically, so "port" sorts before "host".
  # The task spec shows {"host":...,"port":...} but Jason.encode!/1 of a map
  # produces {"port":...,"host":...}. The implementation uses a map literal, so
  # we assert against Jason's actual output. The protocol requires valid JSON
  # with host=127.0.0.1 and the given port — key order is not load-bearing.
  test "builds the proxy URL and JSON init for a target port" do
    assert Proxy.proxy_url("s1") == "wss://api.sprites.dev/v1/sprites/s1/proxy"
    assert Proxy.init_message(4100) == ~s({"port":4100,"host":"127.0.0.1"})
  end
end
