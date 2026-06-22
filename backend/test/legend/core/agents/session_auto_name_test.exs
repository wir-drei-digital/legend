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

  describe ":rename action" do
    setup do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal
        })

      %{session: s}
    end

    test "renames and broadcasts a list change", %{session: s} do
      Phoenix.PubSub.subscribe(Legend.PubSub, Legend.Core.Agents.Notifications.topic())

      {:ok, renamed} = Agents.rename_session(s, %{name: "Polished name"})

      assert renamed.name == "Polished name"
      assert_receive :sessions_changed, 1_000
    end

    test "a blank name resets to nil", %{session: s} do
      {:ok, named} = Agents.rename_session(s, %{name: "Temp"})
      {:ok, cleared} = Agents.rename_session(named, %{name: "   "})
      assert cleared.name == nil
    end

    test "rejects control characters", %{session: s} do
      assert {:error, _} = Agents.rename_session(s, %{name: "bad\tname"})
    end

    test "rejects a name over 120 chars", %{session: s} do
      assert {:error, _} = Agents.rename_session(s, %{name: String.duplicate("x", 121)})
    end
  end
end
