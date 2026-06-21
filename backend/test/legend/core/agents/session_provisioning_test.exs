defmodule Legend.Core.Agents.SessionProvisioningTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :test_runtime_detect)

      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "a provisioning runtime runs detect, installs when missing, and reaches running" do
    TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})
    TestRuntime.set_detect({:ok, %{stdout: "", status: 1}})

    {:ok, session} =
      Agents.start_session(%{name: "p", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :exec, :detect}, 1000
    assert_receive {:test_runtime, :exec, %Legend.Core.Runtime.CommandSpec{}}, 1000
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    assert Agents.get_session!(session.id).status == :running
  end

  test "a provisioning runtime skips install when the harness is already present" do
    TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})
    TestRuntime.set_detect({:ok, %{stdout: "1.0", status: 0}})

    {:ok, session} =
      Agents.start_session(%{name: "found", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :exec, :detect}, 1000
    # Goes straight to start — selective-receiving :start would skip an install
    # exec if one had run, leaving it for the refute below to catch.
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000
    refute_received {:test_runtime, :exec, %Legend.Core.Runtime.CommandSpec{}}

    assert Agents.get_session!(session.id).status == :running
  end

  test "a provisioning runtime with a harness that has no installer fails the session" do
    TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})

    # Hermes declares no provision/1, so provisioning has nothing to install.
    {:ok, session} =
      Agents.start_session(%{name: "noinstaller", harness_id: "hermes", runtime_id: "test"})

    session = Agents.get_session!(session.id)
    assert session.status == :failed
    assert session.error =~ "no installer"
  end

  test "an acp session provisions the claude-code-acp adapter" do
    TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})

    {:ok, _s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    assert_receive {:test_runtime, :exec, :detect}, 1000

    assert_receive {:test_runtime, :exec,
                    %Legend.Core.Runtime.CommandSpec{cmd: "sh", args: ["-lc", install]}},
                   1000

    assert install =~ "@zed-industries/claude-code-acp"
  end

  test "an :api runtime gets NO library/mcp env injected in 2a" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})

    {:ok, _} = Agents.start_session(%{name: "a", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    refute Map.has_key?(spec.env, "LEGEND_LIBRARY")
    refute Map.has_key?(spec.env, "LEGEND_MCP_URL")
  end

  test "a :path runtime still gets library env (unchanged behavior)" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})

    {:ok, _} = Agents.start_session(%{name: "l", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    assert Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end
end
