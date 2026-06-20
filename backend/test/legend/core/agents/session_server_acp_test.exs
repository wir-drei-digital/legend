defmodule Legend.Core.Agents.SessionServerAcpTest do
  use Legend.DataCase, async: false
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "acp session: handshake, conversation id capture, message broadcast" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    # Server wrote the initialize request:
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    # Reply initialize → server writes session/new
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    assert Jason.decode!(new_req)["method"] == "session/new"

    # Reply session/new → conversation id persisted
    new_id = Jason.decode!(new_req)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => new_id,
      "result" => %{"sessionId" => "sess-xyz"}
    })

    # A message chunk broadcasts an item
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-xyz",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hi"}
        }
      }
    })

    assert_receive {:session_event, _seq, %{"type" => "message", "text" => "hi"}}, 1_000

    assert Agents.get_session!(s.id).conversation_id == "sess-xyz"
  end

  test "acp session: a finished turn broadcasts a turn timeline item" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    # Drive the handshake to a live session.
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    new_id = Jason.decode!(new_req)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => new_id,
      "result" => %{"sessionId" => "sess-xyz"}
    })

    drain_test_runtime_writes()

    # Send a prompt and capture the session/prompt frame's request id.
    Agents.SessionServer.acp_prompt(s.id, "hi")
    assert_receive {:test_runtime, :write, prompt_req}, 1_000
    decoded = Jason.decode!(prompt_req)
    assert decoded["method"] == "session/prompt"
    prompt_id = decoded["id"]

    # The agent answers the prompt with a stopReason → a turn item broadcasts.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:session_event, _seq, %{"type" => "turn", "stop_reason" => "end_turn"}}, 1_000
  end

  test "resume of an acp session loads the captured conversation id" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    # Drive the fresh handshake to capture conversation_id "sess-xyz".
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    assert Jason.decode!(new_req)["method"] == "session/new"
    new_id = Jason.decode!(new_req)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => new_id,
      "result" => %{"sessionId" => "sess-xyz"}
    })

    # Wait until the capture is durably persisted before stopping the server.
    assert eventually(fn -> Agents.get_session!(s.id).conversation_id == "sess-xyz" end)

    # Stop the conversation, then resume it — this relaunches the SessionServer
    # with mode :load (conversation_id is set), so it must send session/load.
    Agents.finish_session!(Agents.get_session!(s.id), %{exit_code: 0})
    drain_test_runtime_writes()
    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))

    # The relaunch opens with a fresh initialize…
    assert_receive {:test_runtime, :write, init2}, 1_000
    init2_id = Jason.decode!(init2)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init2_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    # …and then session/load (NOT session/new) with the captured id.
    assert_receive {:test_runtime, :write, load_req}, 1_000
    decoded = Jason.decode!(load_req)
    assert decoded["method"] == "session/load"
    assert decoded["params"]["sessionId"] == "sess-xyz"
  end

  # Poll briefly: the conversation id is persisted from the server process, so it
  # may lag the synchronous response we just fed in.
  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  # Discard any in-flight writes from the prior (fresh) handshake so the next
  # assert_receive sees only the relaunch frames.
  defp drain_test_runtime_writes do
    receive do
      {:test_runtime, :write, _} -> drain_test_runtime_writes()
    after
      0 -> :ok
    end
  end

  defp send_output(id, msg) do
    pid = Legend.Core.Agents.SessionServer.whereis(id)
    send(pid, {:runtime_output, Jason.encode!(msg) <> "\n"})
  end
end
