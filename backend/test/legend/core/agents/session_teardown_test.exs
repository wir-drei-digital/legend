defmodule Legend.Core.Agents.SessionTeardownTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})
    on_exit(fn -> Application.delete_env(:legend, :test_runtime_capabilities) end)
    :ok
  end

  test "destroying a session with a runtime_ref tears down the runtime" do
    {:ok, s} = Agents.start_session(%{name: "t", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    Agents.mark_session_running!(Agents.get_session!(s.id), %{
      runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}
    })

    :ok = Agents.destroy_session(Agents.get_session!(s.id))
    assert_receive {:test_runtime, :teardown, %{"sprite" => _, "exec_id" => "e1"}}, 1000
  end
end
