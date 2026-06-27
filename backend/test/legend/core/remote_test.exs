defmodule Legend.Core.RemoteTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    on_exit(fn -> Remote.clear() end)
    :ok
  end

  @disabled %{
    enabled: false,
    mode: "direct",
    host: nil,
    relay_url: nil,
    relay_handle: nil,
    relay_secret: nil
  }

  test "config defaults to disabled when unset" do
    assert Remote.config() == @disabled
  end

  test "put_config persists and round-trips; clear disables" do
    :ok = Remote.put_config(%{enabled: true, host: "laptop.tailnet.ts.net"})

    assert Remote.config() == %{
             enabled: true,
             mode: "direct",
             host: "laptop.tailnet.ts.net",
             relay_url: nil,
             relay_handle: nil,
             relay_secret: nil
           }

    :ok = Remote.clear()
    assert Remote.config() == @disabled
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

  test "config fail-safes a corrupted non-string host to disabled rather than raising" do
    Legend.Core.Settings.put_setting!(%{
      key: "remote_access",
      value: ~s({"enabled":true,"host":42})
    })

    assert Remote.config() == @disabled
  end

  test "enabled without a host fails safe to disabled" do
    Legend.Core.Settings.put_setting!(%{key: "remote_access", value: ~s({"enabled":true})})
    assert %{enabled: false, host: nil} = Legend.Core.Remote.config()
  end

  test "enabling remote disables force_ssl (http over mesh)" do
    existing = [http: [port: 4807], force_ssl: [rewrite_on: [:x_forwarded_proto]]]
    out = Legend.Core.Remote.endpoint_overrides(existing, %{enabled: true, host: "laptop.ts.net"})
    assert out[:force_ssl] == false
  end

  test "disabling leaves force_ssl untouched" do
    existing = [force_ssl: [rewrite_on: [:x_forwarded_proto]]]
    assert Legend.Core.Remote.endpoint_overrides(existing, %{enabled: false}) == existing
  end

  test "relay ingress is disabled by default" do
    refute Legend.Core.Remote.relay_ingress_enabled?()
  end

  test "direct mode is the default and leaves relay fields nil" do
    :ok = Remote.put_config(%{enabled: true, host: "laptop.ts.net"})
    c = Remote.config()

    assert c.mode == "direct"
    assert c.relay_url == nil
    assert c.relay_handle == nil
    assert c.relay_secret == nil
    refute Remote.relay_ingress_enabled?()
  end

  test "a persisted via_relay config exposes the relay fields and enables the ingress" do
    Legend.Core.Settings.put_setting!(%{
      key: "remote_access",
      value:
        ~s({"enabled":true,"mode":"via_relay","relay_url":"https://relay.example.com","relay_handle":"laptop","relay_secret":"s"})
    })

    c = Remote.config()
    assert c.enabled
    assert c.mode == "via_relay"
    assert c.relay_url == "https://relay.example.com"
    assert c.relay_handle == "laptop"
    assert c.relay_secret == "s"

    assert Remote.relay_ingress_enabled?()
  end

  test "via_relay round-trips through put_config" do
    :ok =
      Remote.put_config(%{
        enabled: true,
        mode: "via_relay",
        relay_url: "https://relay.example.com",
        relay_handle: "laptop",
        relay_secret: "s3cr3t"
      })

    assert Remote.config() == %{
             enabled: true,
             mode: "via_relay",
             host: nil,
             relay_url: "https://relay.example.com",
             relay_handle: "laptop",
             relay_secret: "s3cr3t"
           }

    assert Remote.relay_ingress_enabled?()
  end

  test "via_relay missing a relay field fails safe to disabled (ingress off)" do
    Legend.Core.Settings.put_setting!(%{
      key: "remote_access",
      value:
        ~s({"enabled":true,"mode":"via_relay","relay_url":"https://relay.example.com","relay_handle":"laptop"})
    })

    refute Remote.config().enabled
    refute Remote.relay_ingress_enabled?()
  end
end
