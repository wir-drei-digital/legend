defmodule Legend.Core.Remote.BootTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    original = Application.get_env(:legend, LegendWeb.Endpoint)
    original_ingress = Application.get_env(:legend, LegendWeb.RelayIngressEndpoint)

    on_exit(fn ->
      Application.put_env(:legend, LegendWeb.Endpoint, original)
      Application.put_env(:legend, LegendWeb.RelayIngressEndpoint, original_ingress)
      Remote.clear()
    end)

    :ok
  end

  test "apply! is a no-op when disabled (endpoint stays loopback)" do
    before = Application.get_env(:legend, LegendWeb.Endpoint)
    :ok = Remote.Boot.apply!()
    assert Application.get_env(:legend, LegendWeb.Endpoint) == before
  end

  test "apply! binds 0.0.0.0 when enabled" do
    Remote.put_config(%{enabled: true, host: "laptop.ts.net"})
    :ok = Remote.Boot.apply!()

    http = Application.get_env(:legend, LegendWeb.Endpoint)[:http]
    assert http[:ip] == {0, 0, 0, 0}
  end

  test "apply! in via_relay mode points the ingress origin at <handle>.<relay-host> and leaves the main endpoint loopback" do
    main_before = Application.get_env(:legend, LegendWeb.Endpoint)

    Remote.put_config(%{
      enabled: true,
      mode: "via_relay",
      relay_url: "https://relay.example.com",
      relay_handle: "laptop",
      relay_secret: "s"
    })

    :ok = Remote.Boot.apply!()

    ingress = Application.get_env(:legend, LegendWeb.RelayIngressEndpoint)
    assert ingress[:check_origin] == ["//laptop.relay.example.com"]
    assert ingress[:url][:host] == "laptop.relay.example.com"

    # via_relay must NOT touch the main endpoint (it stays loopback).
    assert Application.get_env(:legend, LegendWeb.Endpoint) == main_before
  end
end
