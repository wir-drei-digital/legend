defmodule Legend.Core.Agents.SessionAutoNameTest do
  use Legend.DataCase, async: false
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :test_runtime_detect)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  describe ":start auto-name from instructions" do
    test "fills a blank name from the instructions" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal,
          instructions: "Fix the login redirect bug"
        })

      assert s.name == "Fix the login redirect bug"
    end

    test "does not override a user-provided name" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal,
          name: "My session",
          instructions: "Fix the login redirect bug"
        })

      assert s.name == "My session"
    end

    test "leaves name nil when there are no instructions" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal
        })

      assert s.name == nil
    end
  end
end
