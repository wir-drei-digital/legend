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

    assert resp["data"]["enabled"] == true
    assert resp["data"]["mode"] == "direct"
    assert resp["data"]["host"] == "laptop.tailnet.ts.net"
    assert resp["restart_required"] == true

    assert Remote.config() == %{
             enabled: true,
             mode: "direct",
             host: "laptop.tailnet.ts.net",
             relay_url: nil,
             relay_handle: nil,
             relay_secret: nil
           }
  end

  test "PUT via_relay persists the relay fields and flags restart_required", %{conn: conn} do
    body = %{
      enabled: true,
      mode: "via_relay",
      relay_url: "https://relay.example.com",
      relay_handle: "laptop",
      relay_secret: "s3cr3t"
    }

    resp = json_response(put(conn, "/api/settings/remote-access", body), 200)

    assert resp["data"]["mode"] == "via_relay"
    assert resp["data"]["relay_url"] == "https://relay.example.com"
    assert resp["data"]["relay_handle"] == "laptop"
    assert resp["restart_required"] == true

    c = Remote.config()
    assert c.mode == "via_relay"
    assert c.relay_url == "https://relay.example.com"
    assert c.relay_handle == "laptop"
    assert c.relay_secret == "s3cr3t"
  end

  test "PUT via_relay missing relay fields is rejected (422)", %{conn: conn} do
    assert json_response(
             put(conn, "/api/settings/remote-access", %{
               enabled: true,
               mode: "via_relay",
               relay_url: "https://relay.example.com"
             }),
             422
           )
  end

  test "PUT via_relay rejects relay fields with control characters (422)", %{conn: conn} do
    assert json_response(
             put(conn, "/api/settings/remote-access", %{
               enabled: true,
               mode: "via_relay",
               relay_url: "https://relay.example.com",
               relay_handle: "bad\x01handle",
               relay_secret: "s"
             }),
             422
           )
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

  test "GET interfaces lists non-loopback IPv4 candidates with a suggested key", %{conn: conn} do
    body = json_response(get(conn, "/api/settings/remote-access/interfaces"), 200)

    assert is_list(body["data"]["candidates"])
    refute "127.0.0.1" in body["data"]["candidates"]
    assert Map.has_key?(body["data"], "suggested")
  end

  test "DELETE disables", %{conn: conn} do
    Remote.put_config(%{enabled: true, host: "x.ts.net"})

    assert %{"data" => %{"enabled" => false}} =
             json_response(delete(conn, "/api/settings/remote-access"), 200)

    assert Remote.config().enabled == false
  end

  test "remote-access config is rejected for a remote (non-loopback) caller", %{conn: conn} do
    # Reconfiguring the network boundary is loopback-only — a remote device
    # token must not reach it.
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> get("/api/settings/remote-access")

    assert json_response(conn, 403) == %{"error" => "loopback only"}
  end
end
