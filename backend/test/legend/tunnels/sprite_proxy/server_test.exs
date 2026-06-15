defmodule Legend.Tunnels.SpriteProxy.ServerTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Tunnels.SpriteProxy.Server

  # Connector that hands back a process relaying {:carrier_out, _} frames to `test`.
  defp relay_connector(test) do
    fn _s, _p, _srv -> {:ok, spawn(fn -> relay_loop(test) end)} end
  end

  defp relay_loop(test) do
    receive do
      {:carrier_out, bin} ->
        send(test, {:carrier_out, bin})
        relay_loop(test)

      _ ->
        relay_loop(test)
    end
  end

  # Connector that records each connect attempt and returns a fresh fake carrier.
  defp connecting_connector(test) do
    fn _s, _p, _srv ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test, {:connected, pid})
      {:ok, pid}
    end
  end

  test "OPEN+DATA dials the loopback target and relays both ways" do
    # a tiny echo TCP server on an ephemeral port stands in for the Phoenix endpoint
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(lsock)
      {:ok, data} = :gen_tcp.recv(c, 0)
      :gen_tcp.send(c, "echo:" <> data)
    end)

    srv =
      start_supervised!(
        {Server,
         [target_port: port, sprite: "s", control_port: 9000, connector: relay_connector(self())]}
      )

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ping"})})

    assert_receive {:carrier_out, bin}, 1000
    {:ok, [%Frame{type: :data, stream_id: 1, payload: "echo:ping"}], ""} = Mux.decode(bin)
  end

  test "connects a carrier on start and reconnects when it drops" do
    test = self()

    start_supervised!(
      {Server,
       [
         target_port: 0,
         sprite: "s1",
         control_port: 9000,
         connector: connecting_connector(test),
         reconnect_base_ms: 10
       ]}
    )

    assert_receive {:connected, carrier1}, 500
    Process.exit(carrier1, :kill)
    assert_receive {:connected, carrier2}, 1000
    assert carrier2 != carrier1
  end

  test "a connector failure retries with backoff" do
    test = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    connector = fn _s, _p, _srv ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(test, {:attempt, n})

      if n == 0,
        do: {:error, :unreachable},
        else: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    start_supervised!(
      {Server,
       [
         target_port: 0,
         sprite: "s1",
         control_port: 9000,
         connector: connector,
         reconnect_base_ms: 10
       ]}
    )

    assert_receive {:attempt, 0}, 500
    assert_receive {:attempt, 1}, 1000
  end

  test "with no target_port it allocates a session-bound listener serving health" do
    srv =
      start_supervised!(
        {Server,
         [
           session_id: "sess-1",
           sprite: "s",
           control_port: 9000,
           connector: fn _s, _p, _srv -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end
         ]}
      )

    port = :sys.get_state(srv).target_port
    assert is_integer(port) and port > 0

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(sock, "GET /api/health HTTP/1.1\r\nHost: x\r\n\r\n")
    {:ok, resp} = :gen_tcp.recv(sock, 0, 1000)
    assert resp =~ "200" and resp =~ "ok"
    :gen_tcp.close(sock)
  end

  test "OPEN beyond the stream cap is refused with a CLOSE" do
    # A real listener so stream 1's dial SUCCEEDS and occupies the only slot;
    # stream 2 then hits the cap and is refused with a CLOSE back out the carrier.
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, _} = :gen_tcp.accept(lsock)
      Process.sleep(:infinity)
    end)

    srv =
      start_supervised!(
        {Server,
         [
           target_port: port,
           sprite: "s",
           control_port: 9000,
           max_streams: 1,
           connector: relay_connector(self())
         ]}
      )

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 2, payload: ""})})

    # stream 1 connected (no CLOSE); only stream 2's cap-refusal frame comes back.
    assert_receive {:carrier_out, bin}, 1000
    assert {:ok, [%Frame{type: :close, stream_id: 2}], ""} = Mux.decode(bin)
  end

  test "the idle sweep closes a stream with no activity" do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, _} = :gen_tcp.accept(lsock)
      Process.sleep(:infinity)
    end)

    srv =
      start_supervised!(
        {Server,
         [
           target_port: port,
           sprite: "s",
           control_port: 9000,
           idle_ms: 0,
           connector: relay_connector(self())
         ]}
      )

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, :sweep)

    assert_receive {:carrier_out, bin}, 1000
    assert {:ok, [%Frame{type: :close, stream_id: 1}], ""} = Mux.decode(bin)
  end

  test "the server notifies :tunnel_ready once the carrier acks" do
    test = self()

    connector = fn _s, _p, srv ->
      send(srv, :carrier_ready)
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    srv =
      start_supervised!(
        {Server,
         [target_port: 0, sprite: "s", control_port: 9000, connector: connector, notify: test]}
      )

    assert_receive {:tunnel_ready, ^srv}, 1000
  end
end
