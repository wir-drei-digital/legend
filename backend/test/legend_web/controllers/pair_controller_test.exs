defmodule LegendWeb.PairControllerTest do
  use LegendWeb.ConnCase, async: true

  alias Legend.Core.Devices

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  test "redeeming a valid code mints a token, even from a non-loopback peer", %{conn: conn} do
    %{code: code} = Devices.generate_pairing_code!()

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> post("/api/pair", %{code: code, name: "iPhone"})

    assert %{"token" => token, "device" => %{"name" => "iPhone"}} = json_response(conn, 200)
    assert is_binary(token)
  end

  test "an invalid code is rejected with 422", %{conn: conn} do
    conn = post(%{conn | remote_ip: {100, 64, 1, 2}}, "/api/pair", %{code: "nope"})
    assert json_response(conn, 422)
  end
end
