defmodule Legend.Core.Agents.SessionTunnelTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)

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
end
