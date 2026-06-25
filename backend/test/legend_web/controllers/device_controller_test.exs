defmodule LegendWeb.DeviceControllerTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Devices

  # All device-management endpoints are loopback by default in ConnCase
  # (build_conn remote_ip is {127,0,0,1}).
  test "generate a pairing code", %{conn: conn} do
    conn = post(conn, "/api/devices/pair-code", %{})
    assert %{"code" => code, "expires_at" => _} = json_response(conn, 200)
    assert is_binary(code)
  end

  test "list and revoke devices", %{conn: conn} do
    device = Devices.create_device!(%{name: "laptop", public_key: nil})

    list = json_response(get(conn, "/api/devices"), 200)
    assert Enum.any?(list["data"], &(&1["id"] == device.id))

    revoked = json_response(delete(conn, "/api/devices/#{device.id}"), 200)
    assert revoked["data"]["revoked_at"]
  end

  test "revoking an unknown device id returns 404", %{conn: conn} do
    conn = delete(conn, "/api/devices/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404) == %{"error" => "device not found"}
  end
end
