defmodule Legend.Core.Agents.SessionServerTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(@valid)
    # The create action starts the server itself; kill that instance so boot!/1
    # below can start its own cleanly. Subscribe only AFTER the auto-started
    # server is gone, so its (fresh) runtime :start never lands in the test
    # mailbox and pollutes assert_receive (it would mask :resume in particular).
    SessionServer.ensure_stopped(session.id)
    Legend.Runtimes.Test.subscribe()
    %{session: session}
  end

  defp boot!(session) do
    {:ok, pid} = SessionServer.start_session(session)
    pid
  end

  test "starting runs the runtime and marks the record running", %{session: session} do
    pid = boot!(session)
    assert Process.alive?(pid)
    assert_receive {:test_runtime, :start, spec, %{cwd: "/tmp", owner: ^pid}}
    assert spec.cmd == "claude"
    assert Agents.get_session!(session.id).status == :running
  end

  test "output is buffered, broadcast with offsets, and replayed on attach", %{session: session} do
    pid = boot!(session)
    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{session.id}")

    send(pid, {:runtime_output, "hello "})
    send(pid, {:runtime_output, "world"})

    assert_receive {:session_output, 0, "hello "}
    assert_receive {:session_output, 6, "world"}

    assert {:ok, %{status: :running, buffer: "hello world", offset: 11}} =
             SessionServer.attach(session.id)
  end

  test "write and resize are forwarded to the runtime", %{session: session} do
    boot!(session)
    :ok = SessionServer.write(session.id, "ls\n")
    assert_receive {:test_runtime, :write, "ls\n"}

    :ok = SessionServer.resize(session.id, 120, 40)
    assert_receive {:test_runtime, :resize, 120, 40}
  end

  test "runtime exit marks record exited, broadcasts, and keeps the server alive", %{
    session: session
  } do
    pid = boot!(session)
    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{session.id}")
    send(pid, {:runtime_output, "bye"})
    send(pid, {:runtime_exit, 0})

    assert_receive {:session_exit, 0}
    record = Agents.get_session!(session.id)
    assert record.status == :exited
    assert record.exit_code == 0

    # Scrollback still attachable after exit.
    assert {:ok, %{status: :exited, buffer: "bye"}} = SessionServer.attach(session.id)
    assert Process.alive?(pid)
  end

  test "stop asks the runtime to terminate", %{session: session} do
    boot!(session)
    :ok = SessionServer.stop(session.id)
    assert_receive {:test_runtime, :stop}
    # Legend.Runtimes.Test.stop sends {:runtime_exit, nil} to the owner.
    eventually(fn -> Agents.get_session!(session.id).status == :exited end)
  end

  test "spawn failure marks the record failed and starts no server" do
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "fail")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(@valid)
    SessionServer.ensure_stopped(session.id)
    assert :ignore = SessionServer.start_session(session)

    record = Agents.get_session!(session.id)
    assert record.status == :failed
    assert record.error == "boom"
    assert {:error, :not_running} = SessionServer.attach(session.id)
  end

  test "ensure_stopped terminates a live server and is a no-op otherwise", %{session: session} do
    pid = boot!(session)
    assert :ok = SessionServer.ensure_stopped(session.id)
    refute Process.alive?(pid)
    assert :ok = SessionServer.ensure_stopped(session.id)
  end

  test "janitor marks orphaned running sessions as interrupted", %{session: session} do
    pid = boot!(session)
    assert Agents.get_session!(session.id).status == :running

    # Simulate a backend restart: the process dies, the record stays :running.
    DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
    assert Agents.get_session!(session.id).status == :running

    Legend.Core.Agents.Janitor.run()

    record = Agents.get_session!(session.id)
    assert record.status == :interrupted
    assert record.error == nil
    assert record.ended_at
  end

  test "attach mid-stream returns the snapshot and live chunks continue at its offset", %{
    session: session
  } do
    pid = boot!(session)
    send(pid, {:runtime_output, "early "})

    eventually(fn ->
      match?({:ok, %{buffer: "early "}}, SessionServer.attach(session.id))
    end)

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{session.id}")
    assert {:ok, %{buffer: "early ", offset: 6}} = SessionServer.attach(session.id)

    send(pid, {:runtime_output, "late"})
    assert_receive {:session_output, 6, "late"}
  end

  test "sessions get LEGEND_LIBRARY env and the harness receives library opts", %{
    session: session
  } do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    assert spec.env["LEGEND_LIBRARY"] == Legend.Core.Library.root()
    # claude_code delivers the primer as CLI args — proof build_command got library opts.
    assert "--append-system-prompt" in spec.args
  end

  test "sessions get MCP env vars and harness opts", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    assert spec.env["LEGEND_SESSION_ID"] == session.id
    assert spec.env["LEGEND_SESSION_TOKEN"] == session.mcp_token
    assert String.ends_with?(spec.env["LEGEND_MCP_URL"], "/api/mcp")
    # claude_code turns the mcp opts into --mcp-config args — proof build_command got them.
    assert "--mcp-config" in spec.args
  end

  test "an inbox message produces one debounced nudge write", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}

    sender =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        name: "researcher"
      })

    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "one"
    })

    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "two"
    })

    assert_receive {:test_runtime, :write, line}, 500
    assert line =~ "2 unread message(s)"
    assert line =~ "researcher"
    assert line =~ "read_messages"
    assert String.ends_with?(line, "\r")

    # Debounce: both messages coalesced into a single write.
    refute_receive {:test_runtime, :write, _}, 200
  end

  test "no nudge after exit", %{session: session} do
    pid = boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}
    send(pid, {:runtime_exit, 0})
    eventually(fn -> Agents.get_session!(session.id).status == :exited end)

    Legend.Core.Signals.send_message!(%{to_session_id: session.id, payload: "anyone home?"})
    refute_receive {:test_runtime, :write, _}, 200
  end

  test "exit posts a system message to the spawner", %{session: session} do
    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: session.id
      })

    SessionServer.ensure_stopped(child.id)
    pid = boot!(child)
    send(pid, {:runtime_exit, 0})

    eventually(fn ->
      Enum.any?(
        Legend.Core.Signals.unread_messages!(session.id),
        &(&1.kind == :system and &1.payload =~ "exited with code 0")
      )
    end)
  end

  test "fresh start passes session_id and fresh mode to the harness", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    index = Enum.find_index(spec.args, &(&1 == "--session-id"))
    assert index
    assert Enum.at(spec.args, index + 1) == session.id
    refute "--resume" in spec.args
  end

  test "resume start passes resume mode to the harness", %{session: session} do
    {:ok, _pid} = SessionServer.start_session(session, :resume)
    assert_receive {:test_runtime, :start, spec, _opts}

    index = Enum.find_index(spec.args, &(&1 == "--resume"))
    assert index
    assert Enum.at(spec.args, index + 1) == session.id
    refute "--session-id" in spec.args
  end

  test "unread messages at start fire a catch-up nudge", %{session: session} do
    sender =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        name: "queued"
      })

    # Message lands while the target session has no live server (it was
    # ensure_stopped in setup) — simulating downtime.
    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "sent while you were away"
    })

    boot!(session)
    assert_receive {:test_runtime, :write, line}, 500
    assert line =~ "1 unread message(s)"
    assert line =~ "queued"
  end

  test "no catch-up nudge when the inbox is empty", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}
    refute_receive {:test_runtime, :write, _}, 200
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
