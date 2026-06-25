defmodule LegendWeb.UserSocketTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.Devices
  alias LegendWeb.{DeviceToken, UserSocket}

  defp connect_with(params, address) do
    connect(UserSocket, params, connect_info: %{peer_data: %{address: address}})
  end

  test "loopback connects without a token" do
    assert {:ok, socket} = connect_with(%{}, {127, 0, 0, 1})
    assert socket.assigns.device_id == nil
  end

  test "non-loopback without a token is refused" do
    assert :error = connect_with(%{}, {100, 64, 1, 2})
  end

  test "non-loopback with a valid token connects and assigns the device id" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    assert {:ok, socket} = connect_with(%{"token" => token}, {100, 64, 1, 2})
    assert socket.assigns.device_id == device.id
  end

  test "non-loopback with a revoked token is refused" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    assert :error = connect_with(%{"token" => token}, {100, 64, 1, 2})
  end

  test "id is per-device for token auth, nil for loopback" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    {:ok, remote} = connect_with(%{"token" => token}, {100, 64, 1, 2})
    {:ok, local} = connect_with(%{}, {127, 0, 0, 1})

    assert UserSocket.id(remote) == "device:#{device.id}"
    assert UserSocket.id(local) == nil
  end
end
