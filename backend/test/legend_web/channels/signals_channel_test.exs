defmodule LegendWeb.SignalsChannelTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    b = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    %{a: a, b: b}
  end

  test "join replays recent messages oldest-first", %{a: a, b: b} do
    Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "old"})
    Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "new"})

    {:ok, %{messages: [first, second]}, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SignalsChannel, "signals:timeline")

    assert first.payload == "old"
    assert second.payload == "new"
    assert first.from_label == "claude_code"
  end

  test "new messages and read events are pushed live", %{a: a, b: b} do
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SignalsChannel, "signals:timeline")

    message =
      Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "live"})

    assert_push "message", %{payload: "live", kind: :message}

    Signals.read_inbox!(b.id)
    assert_push "read", %{session_id: session_id, ids: ids}
    assert session_id == b.id
    assert ids == [message.id]
  end
end
