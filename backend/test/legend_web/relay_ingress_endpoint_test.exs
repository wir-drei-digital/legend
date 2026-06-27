defmodule LegendWeb.RelayIngressEndpointTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint LegendWeb.RelayIngressEndpoint

  setup do
    start_supervised!(LegendWeb.RelayIngressEndpoint)
    :ok
  end

  test "a device-gated/management route without a token is rejected (via_relay, despite loopback conn)" do
    # build_conn() has remote_ip 127.0.0.1; the ingress stamps via_relay, so
    # /api/devices (loopback-only management) is 403 rather than served.
    conn = get(build_conn(), "/api/devices")
    assert conn.status in [401, 403]
  end

  test "/api/mcp is not routed on the relay ingress (404)" do
    conn = post(build_conn(), "/api/mcp", %{})
    assert conn.status == 404
  end

  test "/api/health is reachable through the ingress (200)" do
    conn = get(build_conn(), "/api/health")
    assert conn.status == 200
  end

  test "ingress is configured for a fixed loopback http port" do
    http = Application.get_env(:legend, LegendWeb.RelayIngressEndpoint)[:http]
    assert http[:ip] == {127, 0, 0, 1}
    assert is_integer(http[:port]) and http[:port] > 0
  end
end
