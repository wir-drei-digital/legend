defmodule Legend.Agents.SessionServerTest do
  use Legend.DataCase, async: false

  alias Legend.Agents
  alias Legend.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    Legend.TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(@valid)
    # Forward-compat with Task 7: once the create action starts the server
    # itself, kill that instance so boot!/1 below can start its own cleanly.
    # Before Task 7 this is a no-op.
    SessionServer.ensure_stopped(session.id)
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
    # TestRuntime.stop sends {:runtime_exit, nil} to the owner.
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

  test "janitor marks orphaned running sessions as failed", %{session: session} do
    pid = boot!(session)
    assert Agents.get_session!(session.id).status == :running

    # Simulate a backend restart: the process dies, the record stays :running.
    DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
    assert Agents.get_session!(session.id).status == :running

    Legend.Agents.Janitor.run()

    record = Agents.get_session!(session.id)
    assert record.status == :failed
    assert record.error == "backend restarted"
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
