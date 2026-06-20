defmodule Legend.Core.Acp.ConnectionTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Acp.Connection

  defp decode_lines(frames), do: Enum.map(frames, &Jason.decode!/1)

  # Drive new/1 through initialize + session/new so the connection is ready to
  # reduce session/update notifications.
  defp connected_state do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
        }) <> "\n"
      )

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "sess-xyz"}}) <>
          "\n"
      )

    state
  end

  # Drive new/1 through initialize + session/load so the connection is ready to
  # reduce replayed history (session/update notifications), as on resume.
  defp loaded_state do
    {state, [init]} =
      Connection.new(%{
        cwd: "/tmp",
        mcp_servers: [],
        mode: :load,
        conversation_id: "sess-resumed"
      })

    init_id = Jason.decode!(init)["id"]

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
        }) <> "\n"
      )

    # session/load response (no sessionId in the result).
    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}) <> "\n"
      )

    state
  end

  defp update(kind, fields) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s", "update" => Map.put(fields, "sessionUpdate", kind)}
    }) <> "\n"
  end

  test "new emits initialize; initialize response triggers session/new" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    assert %{"method" => "initialize", "id" => init_id} = Jason.decode!(init)

    resp =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => init_id,
        "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
      }) <> "\n"

    {_state, _items, replies, effects} = Connection.handle_bytes(state, resp)

    assert [%{"method" => "session/new", "params" => %{"cwd" => "/tmp"}}] = decode_lines(replies)
    assert {:load_capable, true} in effects
  end

  test "session/new response captures the conversation id" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
        }) <> "\n"
      )

    # the session/new request id is the next integer
    {_state, _items, _replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "sess-xyz"}}) <>
          "\n"
      )

    assert {:conversation_id, "sess-xyz"} in effects
  end

  test "partial frames buffer until newline" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]

    full =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => init_id,
        "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
      }) <> "\n"

    {a, b} = String.split_at(full, 10)
    {state, _, replies1, _} = Connection.handle_bytes(state, a)
    assert replies1 == []
    {_state, _, replies2, _} = Connection.handle_bytes(state, b)
    assert [%{"method" => "session/new"}] = decode_lines(replies2)
  end

  test "message chunks accumulate into one item" do
    state = connected_state()

    {state, [i1], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "Hel"}})
      )

    {_state, [i2], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "lo"}})
      )

    assert i1["type"] == "message" and i1["text"] == "Hel"
    assert i2["id"] == i1["id"] and i2["text"] == "Hello"
  end

  test "tool_call then tool_call_update merge by id with a diff" do
    state = connected_state()

    {state, [t1], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "tc1",
          "title" => "Edit auth.ex",
          "kind" => "edit",
          "status" => "in_progress"
        })
      )

    {_state, [t2], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "completed",
          "content" => [
            %{"type" => "diff", "path" => "auth.ex", "oldText" => "a", "newText" => "b"}
          ]
        })
      )

    assert t1["id"] == "tc1" and t1["status"] == "in_progress"
    assert t2["id"] == "tc1" and t2["status"] == "completed"
    assert t2["diff"]["newText"] == "b"
  end

  test "a later content-only tool_call_update preserves a previously-set diff" do
    state = connected_state()

    # First update sets a diff.
    {state, [_t1], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "tc1",
          "status" => "in_progress",
          "content" => [
            %{"type" => "diff", "path" => "auth.ex", "oldText" => "a", "newText" => "b"}
          ]
        })
      )

    # Second update carries content (text output) but NO diff block.
    {_state, [t2], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "completed",
          "content" => [%{"type" => "text", "text" => "done"}]
        })
      )

    # The diff from the first update survives; output accumulates.
    assert t2["diff"]["newText"] == "b"
    assert t2["output"] == "done"
  end

  test "prompt sends session/prompt with the agent session id and bumps the turn" do
    state = connected_state()
    {_state, [frame]} = Connection.prompt(state, "do the thing")
    msg = Jason.decode!(frame)
    assert msg["method"] == "session/prompt"
    assert msg["params"]["sessionId"] == "sess-xyz"
    assert [%{"type" => "text", "text" => "do the thing"}] = msg["params"]["prompt"]
  end

  test "turn_in_flight? tracks an outstanding session/prompt" do
    state = connected_state()
    refute Connection.turn_in_flight?(state)

    {state, [frame]} = Connection.prompt(state, "go")
    assert Connection.turn_in_flight?(state)

    prompt_id = Jason.decode!(frame)["id"]

    {state, _items, _replies, _effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "result" => %{"stopReason" => "end_turn"}
        }) <> "\n"
      )

    refute Connection.turn_in_flight?(state)
  end

  test "an error response to a prompt completes the turn lifecycle" do
    state = connected_state()
    {state, [frame]} = Connection.prompt(state, "go")
    prompt_id = Jason.decode!(frame)["id"]

    {state, [item], _replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "error" => %{"code" => -32_000, "message" => "boom"}
        }) <> "\n"
      )

    assert item["type"] == "error"
    # The turn must complete even on failure so the lifecycle/queue can drain.
    assert Enum.any?(effects, &match?({:turn, _}, &1))
    refute Connection.turn_in_flight?(state)
  end

  test "an error response to a non-prompt request does NOT fire a turn effect" do
    # An initialize error must surface a soft error item but no {:turn} effect.
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]

    {_state, [item], _replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "error" => %{"code" => -32_000, "message" => "nope"}
        }) <> "\n"
      )

    assert item["type"] == "error"
    refute Enum.any?(effects, &match?({:turn, _}, &1))
  end

  test "permission request becomes an item; answer responds to the agent" do
    state = connected_state()

    req =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "session/request_permission",
        "params" => %{
          "sessionId" => "sess-xyz",
          "toolCall" => %{"title" => "rm -rf"},
          "options" => [%{"optionId" => "allow", "name" => "Allow"}]
        }
      }) <> "\n"

    {state, [item], _replies, _e} = Connection.handle_bytes(state, req)
    assert item["type"] == "permission" and item["resolved"] == false
    {_state, [reply]} = Connection.answer_permission(state, item["id"], "allow")
    decoded = Jason.decode!(reply)
    assert decoded["id"] == 99
    assert decoded["result"]["outcome"]["outcome"] == "selected"
    assert decoded["result"]["outcome"]["optionId"] == "allow"
  end

  # --- I4: per-turn discrimination on session/load replay ---

  test "I4: session/load replay splits multi-turn history into distinct per-turn items" do
    state = loaded_state()

    # Replayed history: turn 0 (user A, agent A), turn 1 (user B, agent B).
    stream =
      update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "ask A"}}) <>
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "reply A"}}) <>
        update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "ask B"}}) <>
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "reply B"}})

    {_state, items, _replies, _effects} = Connection.handle_bytes(state, stream)

    # The last item per id is the accumulated one; collect final state by id.
    by_id =
      Enum.reduce(items, %{}, fn item, acc -> Map.put(acc, item["id"], item) end)

    assert by_id["user-0"]["text"] == "ask A"
    assert by_id["msg-0"]["text"] == "reply A"
    assert by_id["user-1"]["text"] == "ask B"
    assert by_id["msg-1"]["text"] == "reply B"
    # Exactly four distinct conversational items — not one collapsed pair.
    assert map_size(Map.take(by_id, ["user-0", "msg-0", "user-1", "msg-1"])) == 4
  end

  test "I4: consecutive user chunks with no intervening agent output stay in one turn" do
    state = loaded_state()

    {state, [u1], _, _} =
      Connection.handle_bytes(
        state,
        update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "part 1 "}})
      )

    {_state, [u2], _, _} =
      Connection.handle_bytes(
        state,
        update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "part 2"}})
      )

    assert u1["id"] == "user-0"
    assert u2["id"] == "user-0" and u2["text"] == "part 1 part 2"
  end

  test "I4: a tool_call counts as agent output for the next user turn boundary" do
    state = loaded_state()

    stream =
      update("tool_call", %{"toolCallId" => "tc1", "status" => "completed"}) <>
        update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "next"}})

    {_state, items, _replies, _effects} = Connection.handle_bytes(state, stream)
    user = Enum.find(items, &(&1["type"] == "message" and &1["role"] == "user"))
    # Tool output bumped turn_seen_response, so the user message starts turn 1.
    assert user["id"] == "user-1"
  end

  test "I4: live prompt turn bump is unaffected and resets the boundary flag" do
    state = connected_state()

    # An agent reply on turn 1 (prompt bumps 0 -> 1).
    {state, [_frame]} = Connection.prompt(state, "go")

    {state, [m1], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "answer 1"}})
      )

    assert m1["id"] == "msg-1"

    # Second live prompt -> turn 2; its reply must land on msg-2, not collapse.
    {state, [_frame2]} = Connection.prompt(state, "again")

    {_state, [m2], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "answer 2"}})
      )

    assert m2["id"] == "msg-2" and m2["text"] == "answer 2"
  end

  # --- I9: bounded reduce-map growth + capped tool output ---

  test "I9: a completed tool_call_update drops its id so a later update starts fresh" do
    state = connected_state()

    {state, [_t1], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "tc1",
          "title" => "Run tests",
          "status" => "in_progress",
          "content" => [%{"type" => "text", "text" => "first"}]
        })
      )

    {state, [t2], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "completed",
          "content" => [%{"type" => "text", "text" => " second"}]
        })
      )

    # The emitted completed item is still the full merged entry.
    assert t2["status"] == "completed"
    assert t2["output"] == "first second"
    assert t2["title"] == "Run tests"

    # A stray follow-up for the (dropped) completed id rebuilds a bare base entry:
    # no title carried over, output starts fresh.
    {_state, [t3], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "content" => [%{"type" => "text", "text" => "stray"}]
        })
      )

    assert t3["id"] == "tc1"
    refute Map.has_key?(t3, "title")
    assert t3["output"] == "stray"
  end

  test "I9: a failed tool_call_update also drops its id" do
    state = connected_state()

    {state, [_t1], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{"toolCallId" => "tc1", "title" => "X", "status" => "in_progress"})
      )

    {state, [_t2], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{"toolCallId" => "tc1", "status" => "failed"})
      )

    {_state, [t3], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "content" => [%{"type" => "text", "text" => "after-fail"}]
        })
      )

    refute Map.has_key?(t3, "title")
    assert t3["output"] == "after-fail"
  end

  test "I9: tool output is capped at the configured limit" do
    state = connected_state()
    cap = Connection.max_tool_output()

    # Drive several big in_progress chunks (status not completed, so id survives).
    big = String.duplicate("x", div(cap, 2) + 1000)

    state =
      Enum.reduce(1..4, state, fn _i, st ->
        {st, [_item], _, _} =
          Connection.handle_bytes(
            st,
            update("tool_call_update", %{
              "toolCallId" => "tc1",
              "status" => "in_progress",
              "content" => [%{"type" => "text", "text" => big}]
            })
          )

        st
      end)

    {_state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "in_progress",
          "content" => [%{"type" => "text", "text" => "tail-marker"}]
        })
      )

    assert byte_size(item["output"]) <= cap
    # The tail (most recent output) is retained.
    assert String.ends_with?(item["output"], "tail-marker")
  end

  test "I9: capped tool output is valid UTF-8 even when the cut straddles a multibyte char" do
    state = connected_state()
    cap = Connection.max_tool_output()

    # "→" is a 3-byte UTF-8 char (E2 86 92). Pad so that the kept tail's byte
    # cut lands in the MIDDLE of one of these chars: a naive binary_part would
    # then produce an invalid binary that Jason.encode! raises on.
    multibyte = String.duplicate("→", div(cap, 3) + 1000)

    state =
      Enum.reduce(1..2, state, fn _i, st ->
        {st, [_item], _, _} =
          Connection.handle_bytes(
            st,
            update("tool_call_update", %{
              "toolCallId" => "tc1",
              "status" => "in_progress",
              "content" => [%{"type" => "text", "text" => multibyte}]
            })
          )

        st
      end)

    {_state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "in_progress",
          "content" => [%{"type" => "text", "text" => "tail-marker"}]
        })
      )

    assert byte_size(item["output"]) <= cap
    # The result must be valid UTF-8...
    assert String.valid?(item["output"])
    # ...and therefore encode over the Phoenix channel without raising.
    assert is_binary(Jason.encode!(item))
    assert String.ends_with?(item["output"], "tail-marker")
  end

  test "I9: turn-boundary drop clears the previous turn's user item" do
    state = connected_state()

    # prompt bumps 0 -> 1; accumulate a user item for turn 1.
    {state, [_frame]} = Connection.prompt(state, "go")

    {state, [u1], _, _} =
      Connection.handle_bytes(
        state,
        update("user_message_chunk", %{"content" => %{"type" => "text", "text" => "turn1 user"}})
      )

    assert u1["id"] == "user-1"

    # Next prompt bumps 1 -> 2 and must drop user-1 (alongside msg-/thought-).
    {state, [_frame2]} = Connection.prompt(state, "next")

    # A fresh user chunk on the same id (user-1) would only re-accumulate the
    # OLD text if it survived the drop; instead it must start empty. We probe by
    # replaying a user_message_chunk that the reducer would route to turn 2, then
    # assert the old user-1 entry is gone from reduce by re-creating it cleanly.
    refute Connection.reduce_has_key?(state, "user-1")
  end

  # ACP-2: a newline-less flood must not grow buf unbounded.
  test "buf exceeding the cap resets and emits an error item; valid frames still parse" do
    state = connected_state()
    cap = Connection.max_line_bytes()

    flood = String.duplicate("x", cap + 1)
    {state, items, _replies, _effects} = Connection.handle_bytes(state, flood)

    assert %{"id" => "error-buf", "type" => "error", "text" => text} =
             Enum.find(items, &(&1["id"] == "error-buf"))

    assert text =~ "buffer reset"
    # buf was reset, so a subsequent valid frame parses cleanly.
    {_state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "ok"}})
      )

    assert item["type"] == "message" and item["text"] == "ok"
  end

  # ACP-1: an inbound agent REQUEST we don't handle gets a -32601 reply (not silence).
  test "unhandled agent request yields a -32601 Method not found reply" do
    state = connected_state()

    req =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "fs/read_text_file",
        "params" => %{"path" => "/etc/passwd"}
      }) <> "\n"

    {_state, items, replies, _effects} = Connection.handle_bytes(state, req)

    assert items == []
    assert [%{"jsonrpc" => "2.0", "id" => 99, "error" => err}] = decode_lines(replies)
    assert err["code"] == -32_601
    assert err["message"] == "Method not found"
  end

  # ACP-1: a notification (no id) must still fall through to existing handling.
  test "session/update notification is unaffected by the -32601 clause" do
    state = connected_state()

    {_state, [item], replies, _effects} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "hi"}})
      )

    assert replies == []
    assert item["type"] == "message" and item["text"] == "hi"
  end

  # ACP-5: cancel clears pending perms so a later answer for that id is a no-op.
  test "cancel expires pending permission requests" do
    state = connected_state()

    perm_req =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "session/request_permission",
        "params" => %{
          "toolCall" => %{"title" => "Run command"},
          "options" => [%{"optionId" => "allow", "name" => "Allow"}]
        }
      }) <> "\n"

    {state, [perm_item], _, _} = Connection.handle_bytes(state, perm_req)
    assert perm_item["id"] == "perm-7"

    # Before cancel, answering would produce a reply frame.
    {_state, [_reply]} = Connection.answer_permission(state, "perm-7", "allow")

    # After cancel, the pending entry is cleared -> answering is a no-op.
    {state, [_cancel_frame]} = Connection.cancel(state)
    assert {^state, []} = Connection.answer_permission(state, "perm-7", "allow")
  end
end
