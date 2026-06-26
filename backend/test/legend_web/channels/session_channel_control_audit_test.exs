defmodule LegendWeb.SessionChannelControlAuditTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.{Agents, Devices}

  setup do
    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    on_exit(fn -> Legend.Core.Agents.SessionServer.ensure_stopped(session.id) end)
    %{session: session}
  end

  defp join_as(device_id, session) do
    {:ok, _reply, socket} =
      LegendWeb.UserSocket
      |> socket("device:#{device_id || "local"}", %{device_id: device_id})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    socket
  end

  test "a remote device's stop is audited; a loopback stop is not", %{session: session} do
    socket = join_as("d1", session)
    push(socket, "stop", %{})
    # let the cast round-trip
    _ = :sys.get_state(socket.channel_pid)

    stops = Enum.filter(Devices.list_audit!(), &(&1.action == "stop"))
    assert [%{device_id: "d1", session_id: sid}] = stops
    assert sid == session.id

    local = join_as(nil, session)
    push(local, "stop", %{})
    _ = :sys.get_state(local.channel_pid)
    assert length(Enum.filter(Devices.list_audit!(), &(&1.action == "stop"))) == 1
  end

  test "a remote device's cancel is audited with the socket's device as actor", %{
    session: session
  } do
    socket = join_as("d1", session)
    push(socket, "cancel", %{})
    _ = :sys.get_state(socket.channel_pid)

    cancels = Enum.filter(Devices.list_audit!(), &(&1.action == "cancel"))
    assert [%{device_id: "d1", session_id: sid}] = cancels
    assert sid == session.id

    local = join_as(nil, session)
    push(local, "cancel", %{})
    _ = :sys.get_state(local.channel_pid)
    assert length(Enum.filter(Devices.list_audit!(), &(&1.action == "cancel"))) == 1
  end
end
