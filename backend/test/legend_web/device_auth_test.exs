defmodule LegendWeb.DeviceAuthTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  # /api/runtimes is device-gated and side-effect-free — a good probe.
  test "loopback is allowed without a token", %{conn: conn} do
    conn = %{conn | remote_ip: {127, 0, 0, 1}}
    conn = get(conn, "/api/runtimes")
    assert json_response(conn, 200)
  end

  test "a non-loopback request without a token is rejected", %{conn: conn} do
    conn = %{conn | remote_ip: {100, 64, 1, 2}}
    conn = get(conn, "/api/runtimes")
    assert json_response(conn, 401)
  end

  test "a non-loopback request with a valid token is allowed", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/runtimes")

    assert json_response(conn, 200)
  end

  test "a revoked device's token is rejected", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/runtimes")

    assert json_response(conn, 401)
  end

  test "health is reachable without auth (not gated)", %{conn: conn} do
    conn = %{conn | remote_ip: {100, 64, 1, 2}}
    conn = get(conn, "/api/health")
    assert json_response(conn, 200)
  end

  test "a forwarded-for header does NOT confer loopback trust (no proxy-collapse bypass)", %{
    conn: conn
  } do
    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> get("/api/runtimes")

    assert json_response(conn, 401)
  end
end
