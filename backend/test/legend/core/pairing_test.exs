defmodule Legend.Core.PairingTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Devices
  alias Legend.Core.Devices.{Device, PairingCode}

  test "generate then redeem mints a device" do
    %PairingCode{code: code, expires_at: exp} = Devices.generate_pairing_code!()
    assert is_binary(code) and byte_size(code) >= 8
    assert DateTime.compare(exp, DateTime.utc_now()) == :gt

    assert {:ok, %Device{} = device} =
             Devices.redeem_pairing_code(code, %{name: "phone", public_key: "pk"})

    assert device.name == "phone"
    assert device.public_key == "pk"
  end

  test "a code is single-use" do
    %PairingCode{code: code} = Devices.generate_pairing_code!()
    assert {:ok, _} = Devices.redeem_pairing_code(code, %{name: "a", public_key: nil})
    assert {:error, :used} = Devices.redeem_pairing_code(code, %{name: "b", public_key: nil})
  end

  test "an unknown code is invalid" do
    assert {:error, :invalid} = Devices.redeem_pairing_code("nope", %{name: nil, public_key: nil})
  end

  test "an expired code is rejected" do
    code = Devices.generate_pairing_code!()

    # Force expiry into the past (test-only action).
    code
    |> Ash.Changeset.for_update(:expire_for_test, %{
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Ash.update!()

    assert {:error, :expired} =
             Devices.redeem_pairing_code(code.code, %{name: nil, public_key: nil})
  end
end
