defmodule Legend.Core.Signals.NotificationsTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals
  alias Legend.Core.Signals.Notifications

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    b =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        name: "researcher"
      })

    %{a: a, b: b}
  end

  test "send broadcasts to the recipient inbox and the timeline", %{a: a, b: b} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    message = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "hi"})

    assert_receive {:new_message, %{id: id, from_label: "researcher", payload: "hi"}}
    assert id == message.id
    assert_receive {:signal, %{id: ^id, kind: :message}}
  end

  test "a pre-read message (audit record) skips the inbox but hits the timeline", %{a: a, b: b} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    Signals.send_message!(%{
      from_session_id: b.id,
      to_session_id: a.id,
      kind: :handoff,
      payload: "delivered at launch",
      read_at: DateTime.utc_now()
    })

    refute_receive {:new_message, _}, 100
    assert_receive {:signal, %{kind: :handoff}}
  end

  test "human sender gets the 'human' label", %{a: a} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Signals.send_message!(%{to_session_id: a.id, payload: "hello"})
    assert_receive {:new_message, %{from_label: "human"}}
  end

  test "read_inbox! returns unread oldest-first, marks them read, broadcasts read ids", %{
    a: a,
    b: b
  } do
    m1 = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "one"})
    m2 = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "two"})

    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    assert [r1, r2] = Signals.read_inbox!(a.id)
    assert {r1.id, r2.id} == {m1.id, m2.id}
    assert %DateTime{} = r1.read_at

    assert_receive {:signals_read, %{session_id: session_id, ids: ids}}
    assert session_id == a.id
    assert Enum.sort(ids) == Enum.sort([m1.id, m2.id])

    assert Signals.read_inbox!(a.id) == []
  end
end
