defmodule Legend.Federation.RelayClient.ServerTest do
  use ExUnit.Case, async: false
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Federation.RelayClient.Server

  setup do
    # echo listener standing in for the RelayIngressEndpoint
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(lsock)
    test = self()

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(lsock)
      :inet.setopts(s, active: :once)
      send(test, {:accepted, s})
      echo(s)
    end)

    {:ok, srv} = Server.start_link(%{target_port: port, carrier: self()})
    {:ok, srv: srv}
  end

  defp echo(s) do
    receive do
      {:tcp, ^s, data} ->
        :gen_tcp.send(s, data)
        :inet.setopts(s, active: :once)
        echo(s)

      {:tcp_closed, ^s} ->
        :ok
    end
  end

  test "OPEN connects to the target; DATA round-trips back as a DATA frame", %{srv: srv} do
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    assert_receive {:accepted, _s}, 1000
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ping"})})
    assert_receive {:carrier_out, out}, 1000
    assert {:ok, [%Frame{type: :data, stream_id: 1, payload: "ping"}], ""} = Mux.decode(out)
  end

  test "a {:set_carrier, pid} message updates the carrier the server emits to", %{srv: srv} do
    relay = self()
    other = spawn(fn -> Process.sleep(:infinity) end)

    # Point the server at a throwaway carrier first, then re-point it at us.
    send(srv, {:set_carrier, other})
    send(srv, {:set_carrier, relay})

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 7, payload: ""})})
    assert_receive {:accepted, _s}, 1000
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 7, payload: "pong"})})
    assert_receive {:carrier_out, out}, 1000
    assert {:ok, [%Frame{type: :data, stream_id: 7, payload: "pong"}], ""} = Mux.decode(out)
  end
end
