defmodule Legend.Core.Acp.ConnectionTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Acp.Connection

  defp decode_lines(frames), do: Enum.map(frames, &Jason.decode!/1)

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
end
