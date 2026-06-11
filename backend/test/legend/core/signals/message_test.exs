defmodule Legend.Core.Signals.MessageTest do
  use Legend.DataCase, async: false

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

  test "send creates a message with defaults", %{a: a, b: b} do
    message =
      Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "hello"})

    assert message.kind == :message
    assert message.from_session_id == a.id
    assert message.to_session_id == b.id
    assert message.read_at == nil
  end

  test "send rejects an unknown target session", %{a: a} do
    assert {:error, %Ash.Error.Invalid{}} =
             Signals.send_message(%{
               from_session_id: a.id,
               to_session_id: Ash.UUID.generate(),
               payload: "hello"
             })
  end

  test "send rejects an oversized payload", %{a: a, b: b} do
    assert {:error, %Ash.Error.Invalid{}} =
             Signals.send_message(%{
               from_session_id: a.id,
               to_session_id: b.id,
               payload: String.duplicate("x", 65_537)
             })
  end

  test "from_session_id may be nil (human)", %{b: b} do
    message = Signals.send_message!(%{to_session_id: b.id, payload: "hi from human"})
    assert message.from_session_id == nil
  end

  test "unread_for returns only unread messages for the session, oldest first", %{a: a, b: b} do
    m1 = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "one"})
    m2 = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "two"})
    _other = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "nope"})

    Signals.mark_message_read!(m1)

    assert [unread] = Signals.unread_messages!(b.id)
    assert unread.id == m2.id
  end

  test "mark_read sets read_at", %{a: a, b: b} do
    m = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "x"})
    read = Signals.mark_message_read!(m)
    assert %DateTime{} = read.read_at
  end
end
