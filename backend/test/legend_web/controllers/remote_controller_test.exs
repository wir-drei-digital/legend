defmodule LegendWeb.RemoteControllerTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Remote

  setup do
    on_exit(fn -> Remote.clear() end)
    :ok
  end

  test "GET reflects current config (default disabled)", %{conn: conn} do
    assert %{"data" => %{"enabled" => false, "host" => nil}} =
             json_response(get(conn, "/api/settings/remote-access"), 200)
  end

  test "PUT enables with a host, persists, and flags restart_required", %{conn: conn} do
    body = %{enabled: true, host: "laptop.tailnet.ts.net"}
    resp = json_response(put(conn, "/api/settings/remote-access", body), 200)

    assert resp["data"] == %{"enabled" => true, "host" => "laptop.tailnet.ts.net"}
    assert resp["restart_required"] == true
    assert Remote.config() == %{enabled: true, host: "laptop.tailnet.ts.net"}
  end

  test "PUT enabled without a host is rejected (422)", %{conn: conn} do
    assert json_response(put(conn, "/api/settings/remote-access", %{enabled: true}), 422)
  end

  test "PUT rejects a host with control characters (422)", %{conn: conn} do
    assert json_response(
             put(conn, "/api/settings/remote-access", %{enabled: true, host: "bad\x01host"}),
             422
           )
  end

  test "DELETE disables", %{conn: conn} do
    Remote.put_config(%{enabled: true, host: "x.ts.net"})

    assert %{"data" => %{"enabled" => false}} =
             json_response(delete(conn, "/api/settings/remote-access"), 200)

    assert Remote.config().enabled == false
  end
end
