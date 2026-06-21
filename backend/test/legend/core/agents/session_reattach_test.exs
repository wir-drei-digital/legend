defmodule Legend.Core.Agents.SessionReattachTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)

      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "resume with a persisted runtime_ref reattaches via attach/2" do
    {:ok, s} =
      Agents.start_session(%{
        name: "r",
        harness_id: "claude_code",
        runtime_id: "test",
        transport: :terminal
      })

    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    # Simulate a persisted runtime_ref, then stop + interrupt so the session is resumable.
    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})
    Legend.Core.Agents.SessionServer.ensure_stopped(s.id)
    {:ok, _} = Agents.interrupt_session(Agents.get_session!(s.id))

    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))
    assert_receive {:test_runtime, :attach, %{"sprite" => _, "exec_id" => "e1"}}, 1000
  end
end
