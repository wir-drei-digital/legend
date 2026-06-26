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

  test "pair-code generation is rejected for a remote (non-loopback) caller", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = LegendWeb.DeviceToken.sign(device.id)

    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/devices/pair-code", %{})

    assert json_response(conn, 403) == %{"error" => "loopback only"}
  end

  test "revoke is rejected for a remote (non-loopback) caller", %{conn: conn} do
    device = Devices.create_device!(%{name: "victim", public_key: nil})
    token = LegendWeb.DeviceToken.sign(device.id)

    # A valid remote device token must NOT be able to revoke any device.
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> put_req_header("authorization", "Bearer " <> token)
      |> delete("/api/devices/#{device.id}")

    assert json_response(conn, 403) == %{"error" => "loopback only"}
    # The device is untouched: the loopback plug halts before the controller.
    assert {:ok, fetched} = Devices.get_device(device.id)
    refute fetched.revoked_at
  end

  test "device list is rejected for a remote (non-loopback) caller", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> get("/api/devices")

    assert json_response(conn, 403) == %{"error" => "loopback only"}
  end

  test "audit trail is rejected for a remote (non-loopback) caller", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> get("/api/devices/audit")

    assert json_response(conn, 403) == %{"error" => "loopback only"}
  end

  test "list and revoke devices", %{conn: conn} do
    device = Devices.create_device!(%{name: "laptop", public_key: nil})

    list = json_response(get(conn, "/api/devices"), 200)
    assert Enum.any?(list["data"], &(&1["id"] == device.id))

    revoked = json_response(delete(conn, "/api/devices/#{device.id}"), 200)
    assert revoked["data"]["revoked_at"]
  end

  test "revoke audits the actor (loopback => nil), not the revoked target", %{conn: conn} do
    device = Devices.create_device!(%{name: "old", public_key: nil})
    delete(conn, "/api/devices/#{device.id}")

    rows = Devices.list_audit!() |> Enum.filter(&(&1.action == "revoke"))
    assert Enum.any?(rows), "a revoke audit row should exist"
    # actor is loopback here => device_id nil; it must NOT be the revoked target id
    assert Enum.all?(rows, &(&1.device_id != device.id))
  end

  test "revoking an unknown device id returns 404", %{conn: conn} do
    conn = delete(conn, "/api/devices/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404) == %{"error" => "device not found"}
  end

  test "audit trail returns recorded events with the view shape", %{conn: conn} do
    Devices.audit!(%{device_id: nil, session_id: nil, action: "pair"})

    list = json_response(get(conn, "/api/devices/audit"), 200)
    assert is_list(list["data"])

    event = Enum.find(list["data"], &(&1["action"] == "pair"))
    assert event
    assert Map.has_key?(event, "device_id")
    assert Map.has_key?(event, "session_id")
    assert Map.has_key?(event, "at")
  end
end
