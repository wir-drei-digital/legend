defmodule LegendWeb.SessionChannelAuditTest do
  use LegendWeb.ChannelCase, async: true

  alias Legend.Core.{Agents, Devices}

  test "a remote-device attach is audited; a loopback attach is not" do
    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    # Remote device socket (device_id assigned).
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket("device:d1", %{device_id: "d1"})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    attach = Enum.filter(Devices.list_audit!(), &(&1.action == "attach"))
    assert [%{device_id: "d1", session_id: sid}] = attach
    assert sid == session.id

    # Loopback socket (device_id nil) — no new attach audit.
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket("local", %{device_id: nil})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    assert length(Enum.filter(Devices.list_audit!(), &(&1.action == "attach"))) == 1
  end
end
