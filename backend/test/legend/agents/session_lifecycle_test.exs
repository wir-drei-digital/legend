defmodule Legend.Agents.SessionLifecycleTest do
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

    :ok
  end

  test "start_session creates the record AND starts the server" do
    session = Agents.start_session!(@valid)
    assert_receive {:test_runtime, :start, _spec, _opts}
    assert SessionServer.whereis(session.id)
    assert Agents.get_session!(session.id).status == :running
  end

  test "start_session with a failing spawn returns a :failed record" do
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "fail")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(@valid)
    assert session.status == :failed
    assert session.error == "boom"
    refute SessionServer.whereis(session.id)
  end

  test "destroy_session stops the live server and removes the record" do
    session = Agents.start_session!(@valid)
    pid = SessionServer.whereis(session.id)
    assert pid

    :ok = Agents.destroy_session!(Agents.get_session!(session.id))
    refute Process.alive?(pid)
    assert {:error, _} = Agents.get_session(session.id)
  end
end
