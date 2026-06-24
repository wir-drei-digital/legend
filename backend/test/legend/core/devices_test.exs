defmodule Legend.Core.DevicesTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias Legend.Core.Devices.Device

  describe "device lifecycle" do
    test "create_device! sets paired_at and defaults" do
      device = Devices.create_device!(%{name: "Daniel's iPhone", public_key: nil})

      assert %Device{} = device
      assert device.name == "Daniel's iPhone"
      assert device.public_key == nil
      assert device.paired_at
      assert device.revoked_at == nil
      assert device.last_seen_at == nil
    end

    test "get_device fetches by id; revoke_device! and touch_device! update timestamps" do
      device = Devices.create_device!(%{name: "laptop", public_key: "pk-123"})

      assert {:ok, fetched} = Devices.get_device(device.id)
      assert fetched.id == device.id
      assert fetched.public_key == "pk-123"

      touched = Devices.touch_device!(device)
      assert touched.last_seen_at

      revoked = Devices.revoke_device!(device)
      assert revoked.revoked_at
    end

    test "list_devices returns newest first" do
      a = Devices.create_device!(%{name: "a", public_key: nil})
      b = Devices.create_device!(%{name: "b", public_key: nil})

      ids = Devices.list_devices!() |> Enum.map(& &1.id)
      assert ids == [b.id, a.id]
    end

    test "get_device returns {:error, :not_found} for an absent id" do
      assert {:error, :not_found} =
               Devices.get_device("00000000-0000-0000-0000-000000000000")
    end

    test "name rejects control characters" do
      assert_raise Ash.Error.Invalid, fn ->
        Devices.create_device!(%{name: "bad\x01name", public_key: nil})
      end
    end
  end
end
