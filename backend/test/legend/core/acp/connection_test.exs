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
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "s"}}) <> "\n"
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
end
