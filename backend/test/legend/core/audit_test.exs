defmodule Legend.Core.AuditTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias Legend.Core.Devices.AuditEvent

  test "audit! records an event and list_audit returns newest first" do
    assert %AuditEvent{} = Devices.audit!(%{device_id: nil, session_id: nil, action: "pair"})
    Devices.audit!(%{device_id: nil, session_id: "s1", action: "attach"})

    actions = Devices.list_audit!() |> Enum.map(& &1.action)
    assert actions == ["attach", "pair"]
  end
end
