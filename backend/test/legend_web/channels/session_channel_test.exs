defmodule LegendWeb.SessionChannelTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    Legend.Runtimes.Test.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(@valid)
    %{session: session, server: SessionServer.whereis(session.id)}
  end

  defp join!(session) do
    {:ok, reply, socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    {reply, socket}
  end

  test "join replies with status and scrollback replay", %{session: session, server: server} do
    send(server, {:runtime_output, "earlier output"})
    # Wait until the server has buffered it.
    assert {:ok, %{buffer: "earlier output"}} = await_buffer(session.id, "earlier output")

    {reply, _socket} = join!(session)
    assert reply.status == "running"
    assert Base.decode64!(reply.buffer) == "earlier output"
  end

  test "output after join is pushed base64-encoded", %{session: session, server: server} do
    {_reply, _socket} = join!(session)
    send(server, {:runtime_output, "live"})
    assert_push "output", %{data: data}
    assert Base.decode64!(data) == "live"
  end

  test "input and resize are forwarded to the runtime", %{session: session} do
    {_reply, socket} = join!(session)

    push(socket, "input", %{"data" => "ls\n"})
    assert_receive {:test_runtime, :write, "ls\n"}

    push(socket, "resize", %{"cols" => 100, "rows" => 30})
    assert_receive {:test_runtime, :resize, 100, 30}
  end

  test "stop triggers runtime stop and an exit push", %{session: session} do
    {_reply, socket} = join!(session)
    push(socket, "stop", %{})
    assert_receive {:test_runtime, :stop}
    assert_push "exit", %{exit_code: nil}
  end

  test "joining a dead session falls back to the record", %{session: session} do
    SessionServer.ensure_stopped(session.id)
    Legend.Core.Agents.Janitor.run()

    {reply, _socket} = join!(session)
    assert reply.status == "interrupted"
    assert reply.buffer == ""
    assert reply.error == nil
  end

  test "joining an unknown session is rejected" do
    assert {:error, %{reason: "not found"}} =
             LegendWeb.UserSocket
             |> socket()
             |> subscribe_and_join(
               LegendWeb.SessionChannel,
               "session:00000000-0000-0000-0000-000000000000"
             )
  end

  test "lobby broadcasts changed on session lifecycle events" do
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SessionsLobbyChannel, "sessions:lobby")

    Agents.start_session!(@valid)
    assert_push "changed", %{}
  end

  # The messaging feature added a second channel (signals:timeline) that the
  # sidebar joins on the same socket as the lobby. Guard that joining it does
  # not interfere with the lobby's create→"changed" notification — the contract
  # the session list relies on to show newly created sessions live.
  test "lobby still notifies when signals:timeline shares the socket" do
    socket = socket(LegendWeb.UserSocket)

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, LegendWeb.SignalsChannel, "signals:timeline")

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, LegendWeb.SessionsLobbyChannel, "sessions:lobby")

    Agents.start_session!(@valid)
    assert_push "changed", %{}
  end

  defp await_buffer(id, expected, attempts \\ 50) do
    case SessionServer.attach(id) do
      {:ok, %{buffer: ^expected}} = ok ->
        ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_buffer(id, expected, attempts - 1)

      other ->
        other
    end
  end
end
