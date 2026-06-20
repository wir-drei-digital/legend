defmodule Legend.Core.Agents.SessionTunnelTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :test_tunnel_open)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "an :api runtime with a tunnel opens it and wires the agent to the loopback MCP url" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    {:ok, _} = Agents.start_session(%{name: "t", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_tunnel, :open, %{session_id: _}}, 1000
    assert_receive {:test_runtime, :start, spec, _opts}, 1000

    assert spec.env["LEGEND_MCP_URL"] == "http://127.0.0.1:9999/api/mcp"
    assert is_binary(spec.env["LEGEND_SESSION_TOKEN"])
    refute Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end

  test "destroying the session closes the tunnel" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, s} = Agents.start_session(%{name: "t2", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000

    :ok = Agents.destroy_session(Agents.get_session!(s.id))
    assert_receive {:test_tunnel, :close, _}, 1000
  end

  test "a :path runtime opens no tunnel and keeps the endpoint MCP url" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
    {:ok, _} = Agents.start_session(%{name: "p", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    refute_received {:test_tunnel, :open, _}
    assert Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end

  test "an unregistered tunnel id fails the session" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "no_such_tunnel"})

    {:ok, s} = Agents.start_session(%{name: "u", harness_id: "claude_code", runtime_id: "test"})

    s = Agents.get_session!(s.id)
    assert s.status == :failed
    assert s.error =~ "not registered"
  end

  test "a tunnel that fails to open fails the session without starting the runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    Application.put_env(:legend, :test_tunnel_open, {:error, "carrier down"})

    {:ok, s} = Agents.start_session(%{name: "f", harness_id: "claude_code", runtime_id: "test"})

    s = Agents.get_session!(s.id)
    assert s.status == :failed
    assert s.error =~ "tunnel open failed"
    refute_received {:test_runtime, :start, _spec, _opts}
  end

  test "resume re-opens a fresh tunnel" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    {:ok, s} = Agents.start_session(%{name: "r", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000

    # Simulate a persisted reattach ref, then stop + interrupt so it's resumable.
    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})
    Legend.Core.Agents.SessionServer.ensure_stopped(s.id)
    {:ok, _} = Agents.interrupt_session(Agents.get_session!(s.id))

    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))
    # The carrier died with the backend, so resume opens a fresh tunnel.
    assert_receive {:test_tunnel, :open, _}, 1000
  end

  test "a runtime that fails to start closes the tunnel (no leak)" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    # Make the harness emit cmd "fail", which the Test runtime rejects at start.
    # Override the TERMINAL command + pin :terminal: claude_code now defaults to
    # :acp (Task 3), whose adapter command isn't the one we're stubbing to fail.
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "fail")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    {:ok, s} =
      Agents.start_session(%{
        name: "x",
        harness_id: "claude_code",
        runtime_id: "test",
        transport: :terminal
      })

    assert_receive {:test_tunnel, :open, _}, 1000
    # The fix: the tunnel opened before start_or_attach, so a start failure must
    # close it rather than leak the SpriteProxy.Server.
    assert_receive {:test_tunnel, :close, _}, 1000
    assert Agents.get_session!(s.id).status == :failed
  end

  test "runtime exit closes the tunnel but keeps the session alive for scrollback" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    {:ok, s} =
      Agents.start_session(%{name: "exit", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_tunnel, :open, _}, 1000
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    pid = Legend.Core.Agents.SessionServer.whereis(s.id)
    send(pid, {:runtime_exit, 0})

    assert_receive {:test_tunnel, :close, _}, 1000
    assert Agents.get_session!(s.id).status == :exited
    assert Process.alive?(pid)
  end
end
