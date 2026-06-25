defmodule Legend.Core.RemoteTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    on_exit(fn -> Remote.clear() end)
    :ok
  end

  test "config defaults to disabled when unset" do
    assert Remote.config() == %{enabled: false, host: nil}
  end

  test "put_config persists and round-trips; clear disables" do
    :ok = Remote.put_config(%{enabled: true, host: "laptop.tailnet.ts.net"})
    assert Remote.config() == %{enabled: true, host: "laptop.tailnet.ts.net"}

    :ok = Remote.clear()
    assert Remote.config() == %{enabled: false, host: nil}
  end

  test "endpoint_overrides leaves config untouched when disabled" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4100], check_origin: ["//localhost"]]
    assert Remote.endpoint_overrides(existing, %{enabled: false, host: nil}) == existing
  end

  test "endpoint_overrides binds 0.0.0.0, preserves port, extends check_origin and url when enabled" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4807], check_origin: ["//localhost"]]
    out = Remote.endpoint_overrides(existing, %{enabled: true, host: "laptop.tailnet.ts.net"})

    assert out[:http][:ip] == {0, 0, 0, 0}
    assert out[:http][:port] == 4807
    assert "//laptop.tailnet.ts.net" in out[:check_origin]
    assert "//localhost" in out[:check_origin]
    assert out[:url][:host] == "laptop.tailnet.ts.net"
  end

  test "endpoint_overrides tolerates a missing host (binds 0.0.0.0, no origin/url addition)" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4807], check_origin: ["//localhost"]]
    out = Remote.endpoint_overrides(existing, %{enabled: true, host: nil})

    assert out[:http][:ip] == {0, 0, 0, 0}
    assert out[:check_origin] == ["//localhost"]
  end
end
