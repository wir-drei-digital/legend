defmodule Legend.Core.Signals.SpawnPolicyTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals.Tools
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :allow_remote_host_spawn)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  defp session(runtime_id),
    do: %Legend.Core.Agents.Session{id: Ecto.UUID.generate(), runtime_id: runtime_id, cwd: "/tmp"}

  test "a remote caller may not spawn a host runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert {:error, msg} = Tools.authorize_spawn(session("test"), "local_pty")
    assert msg =~ "may not spawn host"
  end

  test "the override flag allows remote -> host" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    Application.put_env(:legend, :allow_remote_host_spawn, true)
    assert :ok = Tools.authorize_spawn(session("test"), "local_pty")
  end

  test "the same runtime is always allowed (inherit)" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert :ok = Tools.authorize_spawn(session("test"), "test")
  end

  test "a host caller may spawn a host runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
    assert :ok = Tools.authorize_spawn(session("test"), "local_pty")
  end

  test "a local caller may delegate upward to a remote runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert :ok = Tools.authorize_spawn(session("local_pty"), "test")
  end

  test "an unknown target runtime is rejected" do
    assert {:error, msg} = Tools.authorize_spawn(session("test"), "nope")
    assert msg =~ "unknown runtime"
  end

  # Fail-closed classification: a host-side runtime that happens to speak the
  # library over MCP (tunnel: nil, library: :api) must still be gated from a
  # remote caller. Keying host-ness on :library would wrongly let this through.
  test "a host runtime that speaks MCP (tunnel: nil, library: :api) is still gated" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert {:error, msg} = Tools.authorize_spawn(session("test"), "test_host_api")
    assert msg =~ "may not spawn host"
  end

  test "start_agent from a remote session denies a host runtime and creates no child" do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, caller} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000
    before = length(Agents.list_sessions!())

    assert {:error, msg} =
             Tools.dispatch(Agents.get_session!(caller.id), "start_agent", %{
               "harness" => "claude_code",
               "instructions" => "do x",
               "runtime" => "local_pty"
             })

    assert msg =~ "may not spawn host"
    assert length(Agents.list_sessions!()) == before
  end

  test "start_agent inherits the caller's runtime by default" do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, caller} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000

    {:ok, _text} =
      Tools.dispatch(Agents.get_session!(caller.id), "start_agent", %{
        "harness" => "claude_code",
        "instructions" => "child task"
      })

    child = Enum.find(Agents.list_sessions!(), &(&1.spawned_by_session_id == caller.id))
    assert child.runtime_id == "test"
  end
end
