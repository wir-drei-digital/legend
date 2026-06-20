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

  test "I5: items reduce before effects so the turn item outranks the final message chunk" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "hi")
    assert_receive {:test_runtime, :write, prompt_req}, 1_000
    prompt_id = Jason.decode!(prompt_req)["id"]

    # The final agent_message_chunk AND the session/prompt stopReason response
    # arrive in ONE pipe read. The message item must land with a LOWER seq than
    # the turn item even though the response (turn effect) is later in the batch.
    batch =
      [
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{
            "sessionId" => "sess-xyz",
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => %{"type" => "text", "text" => "done"}
            }
          }
        }),
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "result" => %{"stopReason" => "end_turn"}
        })
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    send(Agents.SessionServer.whereis(s.id), {:runtime_output, batch})

    assert_receive {:session_event, msg_seq, %{"type" => "message", "text" => "done"}}, 1_000
    assert_receive {:session_event, turn_seq, %{"type" => "turn"}}, 1_000
    assert msg_seq < turn_seq
  end

  test "a prompt cast mid-turn is queued and flushed on turn completion" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    # Start turn 1.
    Agents.SessionServer.acp_prompt(s.id, "first")
    assert_receive {:test_runtime, :write, p1}, 1_000
    d1 = Jason.decode!(p1)
    assert d1["params"]["prompt"] == [%{"type" => "text", "text" => "first"}]
    first_id = d1["id"]

    # Cast a second prompt WHILE turn 1 is in flight — must NOT write a frame.
    Agents.SessionServer.acp_prompt(s.id, "second")
    refute_receive {:test_runtime, :write, _}, 200

    # Complete turn 1 → the queued prompt is flushed exactly once.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => first_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:test_runtime, :write, p2}, 1_000
    assert Jason.decode!(p2)["params"]["prompt"] == [%{"type" => "text", "text" => "second"}]
  end

  test "a mid-turn nudge defers: a UI nudge item appears but no prompt is sent until the turn ends" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    # Put a turn in flight.
    Agents.SessionServer.acp_prompt(s.id, "work")
    assert_receive {:test_runtime, :write, p1}, 1_000
    first_id = Jason.decode!(p1)["id"]

    # Deliver a nudge mid-turn directly (bypass the debounce timer).
    send(
      Agents.SessionServer.whereis(s.id),
      {:new_message, %{from_label: "human"}}
    )

    send(Agents.SessionServer.whereis(s.id), :nudge_flush)

    # A structured nudge UI item is broadcast (stable id "nudge")…
    assert_receive {:session_event, _seq, %{"id" => "nudge", "type" => "nudge"} = nudge}, 1_000
    assert nudge["count"] == 1
    # …but NO session/prompt frame while the turn is in flight.
    refute_receive {:test_runtime, :write, _}, 200

    # Completing the turn flushes the deferred nudge as a prompt.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => first_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:test_runtime, :write, nudge_prompt}, 1_000
    assert Jason.decode!(nudge_prompt)["method"] == "session/prompt"
  end

  test "an idle nudge sends a prompt immediately" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    send(
      Agents.SessionServer.whereis(s.id),
      {:new_message, %{from_label: "human"}}
    )

    send(Agents.SessionServer.whereis(s.id), :nudge_flush)

    # Idle (no turn in flight, session id captured) → prompt sent now.
    assert_receive {:test_runtime, :write, nudge_prompt}, 1_000
    assert Jason.decode!(nudge_prompt)["method"] == "session/prompt"
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

  test "answering an unknown permission request id is a no-op" do
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

    # No permission request was ever issued — answering a stale/unknown id must
    # not write a reply frame to the runtime nor broadcast a resolved item.
    Agents.SessionServer.acp_permission(s.id, "perm-does-not-exist", "allow")

    refute_receive {:test_runtime, :write, _}, 200
    refute_receive {:session_event, _seq, _item}, 200

    # The server is still alive and healthy.
    assert Process.alive?(Agents.SessionServer.whereis(s.id))
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

  # Drive the ACP launch handshake (initialize → session/new) so the connection
  # has a captured session id and is ready to accept prompts.
  defp drive_to_live(id) do
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    send_output(id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    new_id = Jason.decode!(new_req)["id"]

    send_output(id, %{
      "jsonrpc" => "2.0",
      "id" => new_id,
      "result" => %{"sessionId" => "sess-xyz"}
    })
  end
end
