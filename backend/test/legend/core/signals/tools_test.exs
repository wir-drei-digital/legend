defmodule Legend.Core.Signals.ToolsTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals
  alias Legend.Core.Signals.Tools

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

  test "tool list exposes the five tools" do
    names = Enum.map(Tools.list(), & &1.name)

    assert Enum.sort(names) ==
             ["handoff", "list_agents", "read_messages", "send_message", "start_agent"]

    assert Enum.all?(Tools.list(), &match?(%{inputSchema: %{type: "object"}}, &1))
  end

  test "send_message delivers to a session id", %{a: a, b: b} do
    assert {:ok, text} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "hi"})
    assert text =~ "Delivered"
    assert [%{payload: "hi", from_session_id: from}] = Signals.unread_messages!(b.id)
    assert from == a.id
  end

  test "send_message to 'requester' resolves the spawner", %{a: a} do
    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: a.id
      })

    assert {:ok, _} =
             Tools.dispatch(child, "send_message", %{"to" => "requester", "content" => "done"})

    assert [%{payload: "done"}] = Signals.unread_messages!(a.id)

    assert {:error, text} =
             Tools.dispatch(a, "send_message", %{"to" => "requester", "content" => "x"})

    assert text =~ "no requester"
  end

  test "send_message to an unknown session errors", %{a: a} do
    assert {:error, text} =
             Tools.dispatch(a, "send_message", %{"to" => Ash.UUID.generate(), "content" => "x"})

    assert text =~ "unknown session"
  end

  test "read_messages drains the inbox", %{a: a, b: b} do
    {:ok, _} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "first"})
    {:ok, _} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "second"})

    assert {:ok, text} = Tools.dispatch(b, "read_messages", %{})
    assert text =~ "first"
    assert text =~ "second"

    assert {:ok, "No unread messages."} = Tools.dispatch(b, "read_messages", %{})
  end

  test "start_agent spawns a session with lineage, instructions, and audit record", %{a: a} do
    assert {:ok, text} =
             Tools.dispatch(a, "start_agent", %{
               "harness" => "hermes",
               "instructions" => "summarize the README",
               "name" => "summarizer"
             })

    assert text =~ "Started session"

    child = Enum.find(Agents.list_sessions!(), &(&1.name == "summarizer"))
    assert child.spawned_by_session_id == a.id
    assert child.instructions == "summarize the README"
    assert child.cwd == a.cwd

    # Audit record on the timeline, already read (delivered at launch).
    assert Signals.unread_messages!(child.id) == []

    assert Enum.any?(
             Signals.list_messages!(),
             &(&1.kind == :system and &1.to_session_id == child.id)
           )
  end

  test "start_agent rejects unknown harness and enforces the session cap", %{a: a} do
    assert {:error, text} =
             Tools.dispatch(a, "start_agent", %{"harness" => "nope", "instructions" => "x"})

    assert text =~ "unknown harness"

    original = Application.get_env(:legend, :max_running_sessions)
    Application.put_env(:legend, :max_running_sessions, 1)
    on_exit(fn -> Application.put_env(:legend, :max_running_sessions, original) end)

    assert {:error, text} =
             Tools.dispatch(a, "start_agent", %{"harness" => "hermes", "instructions" => "x"})

    assert text =~ "session cap"
  end

  test "handoff to an existing session sends a :handoff message", %{a: a, b: b} do
    assert {:ok, _} = Tools.dispatch(a, "handoff", %{"to" => b.id, "summary" => "take over"})
    assert [%{kind: :handoff, payload: "take over"}] = Signals.unread_messages!(b.id)
  end

  test "handoff to a harness id spawns with the summary as launch context", %{a: a} do
    assert {:ok, text} =
             Tools.dispatch(a, "handoff", %{
               "to" => "hermes",
               "summary" => "state: done X, next Y"
             })

    assert text =~ "Handed off"

    child = Enum.find(Agents.list_sessions!(), &(&1.spawned_by_session_id == a.id))
    assert child.instructions =~ "state: done X, next Y"
  end

  test "handoff to an id that is neither errors", %{a: a} do
    assert {:error, text} = Tools.dispatch(a, "handoff", %{"to" => "nope", "summary" => "x"})
    assert text =~ "unknown session or harness"
  end

  test "list_agents lists sessions with status", %{a: a} do
    assert {:ok, text} = Tools.dispatch(a, "list_agents", %{})
    assert text =~ a.id
    assert text =~ "claude_code"
  end

  test "unknown tool errors", %{a: a} do
    assert {:error, _} = Tools.dispatch(a, "fly_to_moon", %{})
  end

  test "messaging_primer mentions the session id and the requester when spawned", %{a: a} do
    primer = Signals.messaging_primer(a)
    assert primer =~ a.id
    refute primer =~ "You were started by"

    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: a.id
      })

    child_primer = Signals.messaging_primer(child)
    assert child_primer =~ "You were started by session #{a.id}"
  end
end
