defmodule Legend.Core.Agents.SessionServerAcpTest do
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

  test "acp launch encodes MCP http headers as an array of {name, value} (ACP schema)" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    # Reply initialize so the server emits session/new carrying the mcpServers.
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    params = Jason.decode!(new_req)["params"]

    assert [server] = params["mcpServers"]
    assert server["type"] == "http"

    # ACP's zMcpServerHttp requires headers as Array<{name, value}>. A bare map
    # fails the adapter's zod validation with JSON-RPC -32602 "Invalid params",
    # which fails the handshake and marks the session :failed.
    assert [%{"name" => "Authorization", "value" => "Bearer " <> _}] = server["headers"]
  end

  test "acp session: sending a prompt broadcasts the user's message as a timeline item" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    # The human sends a prompt. It must immediately appear in the stream as a
    # user-role message item — not only after a later session/load replay.
    Agents.SessionServer.acp_prompt(s.id, "hello agent")

    assert_receive {:session_event, _seq,
                    %{"type" => "message", "role" => "user", "text" => "hello agent"}},
                   1_000
  end

  test "acp session: a queued (mid-turn) prompt shows as a user message when it is sent" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    # Turn 1 in flight (its own user item broadcasts now).
    Agents.SessionServer.acp_prompt(s.id, "first")

    assert_receive {:session_event, _seq,
                    %{"type" => "message", "role" => "user", "text" => "first"}},
                   1_000

    assert_receive {:test_runtime, :write, p1}, 1_000
    first_id = Jason.decode!(p1)["id"]

    # A second prompt arrives mid-turn → server-side queue, no user item yet.
    Agents.SessionServer.acp_prompt(s.id, "second")
    refute_receive {:session_event, _seq, %{"role" => "user", "text" => "second"}}, 200

    # Completing the turn flushes the queued prompt → its user item broadcasts.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => first_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:session_event, _seq,
                    %{"type" => "message", "role" => "user", "text" => "second"}},
                   1_000
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

  test "the mid-turn prompt queue is bounded: overflow prompts are dropped and logged" do
    import ExUnit.CaptureLog

    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    cap = 50

    # Start turn 1 (sent immediately — does not occupy the queue).
    Agents.SessionServer.acp_prompt(s.id, "first")
    assert_receive {:test_runtime, :write, p1}, 1_000
    d1 = Jason.decode!(p1)
    assert d1["params"]["prompt"] == [%{"type" => "text", "text" => "first"}]
    first_id = d1["id"]

    # Fill the queue to exactly the cap while the turn is in flight. None of
    # these write a frame (one-turn-at-a-time).
    for i <- 1..cap do
      Agents.SessionServer.acp_prompt(s.id, "queued-#{i}")
    end

    refute_receive {:test_runtime, :write, _}, 200

    # Two more prompts past the cap must be dropped (newest-first) and logged —
    # the queue must not grow beyond the cap.
    log =
      capture_log(fn ->
        Agents.SessionServer.acp_prompt(s.id, "overflow-1")
        Agents.SessionServer.acp_prompt(s.id, "overflow-2")
        # Let the casts be processed before reading state/log.
        _ = :sys.get_state(Agents.SessionServer.whereis(s.id))
      end)

    assert log =~ "prompt queue full"

    state = :sys.get_state(Agents.SessionServer.whereis(s.id))
    assert length(state.acp_prompt_queue) == cap

    # The dropped (newest) prompts must never be sent. Complete the turn → the
    # FIRST queued prompt (oldest accepted) flushes; the overflow ones are gone.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => first_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:test_runtime, :write, p2}, 1_000
    assert Jason.decode!(p2)["params"]["prompt"] == [%{"type" => "text", "text" => "queued-1"}]
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

  test "I1: a runtime_stderr message never reaches the timeline or decoder" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)
    drain_test_runtime_writes()

    pid = Agents.SessionServer.whereis(s.id)

    # A stderr write that would corrupt a JSON-RPC frame if spliced into stdout.
    send(pid, {:runtime_stderr, "node: some diagnostic noise\n{partial-json"})

    # It must NOT produce a timeline item (it never reaches Acp.Connection).
    refute_receive {:session_event, _seq, _item}, 200

    # A valid frame delivered AFTER the stderr still parses cleanly — proving the
    # stderr did not corrupt the decoder's line buffer.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-xyz",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "after-stderr"}
        }
      }
    })

    assert_receive {:session_event, _seq, %{"type" => "message", "text" => "after-stderr"}}, 1_000
    assert Process.alive?(pid)
  end

  test "I6: an error response to initialize marks the session :failed" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    # The adapter answers initialize with a JSON-RPC ERROR — fatal per spec.
    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "error" => %{"code" => -32_600, "message" => "unsupported protocol version"}
    })

    assert_receive {:session_status, :failed}, 1_000
    assert eventually(fn -> Agents.get_session!(s.id).status == :failed end)
    assert Agents.get_session!(s.id).error =~ "unsupported protocol version"
  end

  test "I6: the handshake watchdog marks the session :failed if no handshake completes" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    # Server wrote the initialize request but the adapter stays silent.
    assert_receive {:test_runtime, :write, _init}, 1_000

    # Simulate the watchdog firing (timer is armed → not a stale no-op).
    send(Agents.SessionServer.whereis(s.id), :acp_handshake_timeout)

    assert_receive {:session_status, :failed}, 1_000
    assert eventually(fn -> Agents.get_session!(s.id).status == :failed end)
    assert Agents.get_session!(s.id).error =~ "handshake timed out"
  end

  test "I6: a completed handshake cancels the watchdog (no spurious failure)" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")
    drive_to_live(s.id)

    # Handshake completed → {:session_ready} disarmed the watchdog. A stale
    # timeout message must be a no-op and leave the session :running.
    send(Agents.SessionServer.whereis(s.id), :acp_handshake_timeout)

    refute_receive {:session_status, :failed}, 200
    assert Agents.get_session!(s.id).status == :running
    assert Process.alive?(Agents.SessionServer.whereis(s.id))
  end

  test "an interrupted ACP session resumes by relaunching (session/load), never attach" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})

    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})
    Legend.Core.Agents.SessionServer.ensure_stopped(s.id)
    {:ok, _} = Agents.interrupt_session(Agents.get_session!(s.id))

    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))
    assert_receive {:test_runtime, :start, _spec2, _opts2}, 1000
    refute_receive {:test_runtime, :attach, _}, 300
  end

  test "a transport switch starts a fresh process, never attaching the old transport's exec" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})

    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :terminal})

    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "term1"}})
    Agents.set_session_transport!(s, %{transport: :acp})

    assert_receive {:test_runtime, :start, _spec2, _opts2}, 1000
    refute_receive {:test_runtime, :attach, _}, 300
  end

  test "acp→terminal switch passes --resume (not --session-id) to the terminal harness" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})

    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    assert_receive {:test_runtime, :start, _acp_spec, _opts}, 1000

    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "acp1"}})
    Agents.set_session_transport!(s, %{transport: :terminal})

    assert_receive {:test_runtime, :start, spec, _opts2}, 1000

    # conversation_mode(:switch) → :resume so the terminal harness emits --resume
    assert "--resume" in spec.args
    refute "--session-id" in spec.args
    # The resume id is conversation_id || session.id; for a fresh ACP session
    # that hasn't completed the handshake, conversation_id is nil → session.id.
    resume_id = Agents.get_session!(s.id).conversation_id || s.id
    resume_idx = Enum.find_index(spec.args, &(&1 == "--resume"))
    assert Enum.at(spec.args, resume_idx + 1) == resume_id
  end

  test "acp session: the first prompt auto-names a blank session" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "Refactor the auth module")

    assert eventually(fn -> Agents.get_session!(s.id).name == "Refactor the auth module" end)
  end

  test "acp session: the first prompt does not overwrite a user-provided name" do
    {:ok, s} =
      Agents.start_session(%{
        harness_id: "claude_code",
        runtime_id: "test",
        transport: :acp,
        name: "My session"
      })

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "Refactor the auth module")
    # Let the cast finish processing before reading the record.
    _ = :sys.get_state(Agents.SessionServer.whereis(s.id))

    assert Agents.get_session!(s.id).name == "My session"
  end

  test "acp session: only the first prompt names the session" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "First task here")
    assert eventually(fn -> Agents.get_session!(s.id).name == "First task here" end)

    # A later prompt (queued behind the in-flight first turn) must NOT re-derive.
    Agents.SessionServer.acp_prompt(s.id, "A completely different second task")
    _ = :sys.get_state(Agents.SessionServer.whereis(s.id))

    assert Agents.get_session!(s.id).name == "First task here"
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
