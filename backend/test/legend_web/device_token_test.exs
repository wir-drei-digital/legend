defmodule LegendWeb.DeviceTokenTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  test "round-trips a valid device" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    assert {:ok, loaded} = DeviceToken.verify(token)
    assert loaded.id == device.id
  end

  test "rejects a garbage token" do
    assert {:error, :invalid} = DeviceToken.verify("not-a-token")
  end

  test "rejects a token for a revoked device" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    assert {:error, :revoked} = DeviceToken.verify(token)
  end

  test "rejects a token whose device no longer exists" do
    token = DeviceToken.sign(Ecto.UUID.generate())
    assert {:error, :invalid} = DeviceToken.verify(token)
  end
end
