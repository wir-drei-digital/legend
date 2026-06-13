defmodule Legend.Tunnels.SpriteProxy.ServerTest do
  use ExUnit.Case
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Tunnels.SpriteProxy.Server

  test "OPEN+DATA dials the loopback target and relays both ways" do
    # a tiny echo TCP server on an ephemeral port stands in for the Phoenix endpoint
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(lsock)
      {:ok, data} = :gen_tcp.recv(c, 0)
      :gen_tcp.send(c, "echo:" <> data)
    end)

    {:ok, srv} = Server.start_link(target_port: port)
    # outbound frames arrive here as {:carrier_out, bin}
    Server.set_out(srv, self())
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ping"})})

    assert_receive {:carrier_out, bin}, 1000
    {[%Frame{type: :data, stream_id: 1, payload: "echo:ping"}], ""} = Mux.decode(bin)
  end
end
