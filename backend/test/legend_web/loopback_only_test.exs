defmodule LegendWeb.LoopbackOnlyTest do
  use LegendWeb.ConnCase, async: true

  test "loopback passes" do
    conn = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> LegendWeb.LoopbackOnly.call([])
    refute conn.halted
  end

  test "via_relay on loopback is rejected (403)" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> LegendWeb.ViaRelay.stamp()
      |> LegendWeb.LoopbackOnly.call([])

    assert conn.status == 403
    assert conn.halted
  end
end
