defmodule Legend.Agents.SessionTest do
  use Legend.DataCase, async: false

  alias Legend.Agents

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp", name: "demo"}

  test "start creates a session in :starting" do
    session = Agents.start_session!(@valid)
    assert session.status == :starting
    assert session.harness_id == "claude_code"
    assert session.cwd == "/tmp"
  end

  test "cwd defaults to the user home" do
    session = Agents.start_session!(Map.delete(@valid, :cwd))
    assert session.cwd == System.user_home!()
  end

  test "runtime_id defaults to local_pty" do
    # Point the harness at a nonexistent binary so this stays safe after Task 7
    # wires the create hook (LocalPty would otherwise spawn a real `claude`).
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "no-such-binary-xyz")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(Map.delete(@valid, :runtime_id))
    assert session.runtime_id == "local_pty"
  end

  test "rejects unknown harness and runtime ids" do
    assert {:error, %Ash.Error.Invalid{}} =
             Agents.start_session(%{@valid | harness_id: "nope"})

    assert {:error, %Ash.Error.Invalid{}} =
             Agents.start_session(%{@valid | runtime_id: "nope"})
  end

  test "status transitions: mark_running, finish, fail" do
    session = Agents.start_session!(@valid)

    running = Agents.mark_session_running!(session)
    assert running.status == :running
    assert running.started_at

    finished = Agents.finish_session!(running, %{exit_code: 0})
    assert finished.status == :exited
    assert finished.exit_code == 0
    assert finished.ended_at

    failed = Agents.fail_session!(Agents.start_session!(@valid), %{error: "spawn failed"})
    assert failed.status == :failed
    assert failed.error == "spawn failed"
  end

  test "list and get" do
    session = Agents.start_session!(@valid)
    assert Enum.any?(Agents.list_sessions!(), &(&1.id == session.id))
    assert Agents.get_session!(session.id).id == session.id
  end

  test "destroy removes the record" do
    session = Agents.start_session!(@valid)
    assert :ok = Agents.destroy_session!(session)
    assert {:error, %Ash.Error.Invalid{}} = Agents.get_session(session.id)
  end
end
