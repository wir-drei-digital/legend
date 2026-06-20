defmodule LegendWeb.SessionChannelAcpTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Agents.SessionServer

  # SessionChannel's ACP surface: join replies with the reduced-item snapshot +
  # cursor (JSON, not base64) and forwards prompt/cancel/set_mode/permission to
  # the matching SessionServer ACP casts. The Test runtime observes the frames
  # the SessionServer writes (`{:test_runtime, :write, frame}`).
  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp", transport: :acp}

  setup do
    Legend.Runtimes.Test.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  # Drive the ACP launch handshake (initialize → session/new) so the connection
  # is past setup and a captured conversation id is in place. Mirrors the Task 9
  # SessionServer ACP test helper.
  defp drive_handshake(id) do
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    send_output(id, %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}
    })

    assert_receive {:test_runtime, :write, new_req}, 1_000
    assert Jason.decode!(new_req)["method"] == "session/new"
    new_id = Jason.decode!(new_req)["id"]

    send_output(id, %{
      "jsonrpc" => "2.0",
      "id" => new_id,
      "result" => %{"sessionId" => "sess-xyz"}
    })
  end

  defp send_output(id, msg) do
    pid = SessionServer.whereis(id)
    send(pid, {:runtime_output, Jason.encode!(msg) <> "\n"})
  end

  defp join!(session) do
    {:ok, reply, socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    {reply, socket}
  end

  test "acp join replies with items + cursor and forwards prompts" do
    {:ok, s} = Agents.start_session(@valid)
    drive_handshake(s.id)

    {reply, socket} = join!(s)

    assert reply.status == "running"
    assert reply.transport == "acp"
    assert is_list(reply.items)
    assert is_integer(reply.cursor)
    # No terminal scrollback on an ACP join.
    refute Map.has_key?(reply, :buffer)

    push(socket, "prompt", %{"content" => "hello"})

    assert_receive {:test_runtime, :write, frame}
    decoded = Jason.decode!(frame)
    assert decoded["method"] == "session/prompt"
    assert decoded["params"]["prompt"] == [%{"type" => "text", "text" => "hello"}]
  end

  test "cancel/set_mode/permission forward to the runtime as ACP frames" do
    {:ok, s} = Agents.start_session(@valid)
    drive_handshake(s.id)

    {_reply, socket} = join!(s)

    push(socket, "cancel", %{})
    assert_receive {:test_runtime, :write, cancel}
    assert Jason.decode!(cancel)["method"] == "session/cancel"

    push(socket, "set_mode", %{"mode" => "plan"})
    assert_receive {:test_runtime, :write, set_mode}
    decoded_mode = Jason.decode!(set_mode)
    assert decoded_mode["method"] == "session/set_mode"
    assert decoded_mode["params"]["modeId"] == "plan"
  end

  test "non-string/non-list prompt content does not crash the session" do
    {:ok, s} = Agents.start_session(@valid)
    drive_handshake(s.id)

    {_reply, _socket} = join!(s)

    server = SessionServer.whereis(s.id)
    assert is_pid(server) and Process.alive?(server)

    # Defense in depth: bad content that bypasses the channel guard (e.g. an
    # internal caller) still must not crash the restart: :temporary SessionServer —
    # to_blocks/1's catch-all returns [] (an empty prompt) instead of raising a
    # FunctionClauseError that would permanently kill the session.
    for bad <- [42, %{"oops" => true}, true, nil] do
      SessionServer.acp_prompt(s.id, bad)
    end

    # A subsequent valid prompt still flows through — proves the server survived.
    SessionServer.acp_prompt(s.id, "still here")

    assert eventually_receives_prompt([%{"type" => "text", "text" => "still here"}])
    assert Process.alive?(server)
  end

  # Drain session/prompt frames until one carries the expected prompt blocks
  # (the bad-content prompts emit empty-prompt frames first).
  defp eventually_receives_prompt(expected) do
    receive do
      {:test_runtime, :write, frame} ->
        case Jason.decode!(frame) do
          %{"method" => "session/prompt", "params" => %{"prompt" => ^expected}} -> true
          _ -> eventually_receives_prompt(expected)
        end
    after
      1_000 -> false
    end
  end

  test "session events are pushed as event frames with a seq cursor" do
    {:ok, s} = Agents.start_session(@valid)
    drive_handshake(s.id)

    {_reply, _socket} = join!(s)

    # A streamed agent message chunk reduces to a timeline item and broadcasts.
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

    assert_push "event", %{seq: seq, item: %{"type" => "message", "text" => "hi"}}
    assert is_integer(seq)
  end
end
