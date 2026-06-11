defmodule Legend.Core.Agents.SessionTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp", name: "demo"}

  test "start creates a session and reports its live status" do
    session = Agents.start_session!(@valid)
    assert session.status == :running
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

  describe "messaging fields" do
    setup do
      on_exit(fn ->
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
          DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
        end
      end)
    end

    test "start accepts spawned_by_session_id and instructions" do
      parent =
        Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

      child =
        Agents.start_session!(%{
          harness_id: "hermes",
          runtime_id: "test",
          cwd: "/tmp",
          spawned_by_session_id: parent.id,
          instructions: "summarize the README"
        })

      assert child.spawned_by_session_id == parent.id
      assert child.instructions == "summarize the README"
    end

    test "every session gets a unique mcp_token and is fetchable by it" do
      a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
      b = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

      assert is_binary(a.mcp_token) and byte_size(a.mcp_token) >= 24
      assert a.mcp_token != b.mcp_token

      assert {:ok, found} = Agents.get_session_by_token(a.mcp_token)
      assert found.id == a.id
      assert {:error, _} = Agents.get_session_by_token("nope")
    end

    test "mcp_token cannot be forged through :start" do
      # mcp_token is not an accepted input on the :start action, so Ash rejects
      # the forged key outright (NoSuchInput) rather than silently dropping it.
      assert_raise Ash.Error.Invalid, fn ->
        Agents.start_session!(%{
          harness_id: "claude_code",
          runtime_id: "test",
          cwd: "/tmp",
          mcp_token: "forged"
        })
      end
    end
  end
end
