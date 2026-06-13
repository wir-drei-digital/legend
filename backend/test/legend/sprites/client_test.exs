defmodule Legend.Sprites.ClientTest do
  use ExUnit.Case, async: true
  alias Legend.Sprites.Client

  setup do
    Application.put_env(:legend, :sprites_token, "tkn")

    Req.Test.stub(Legend.Sprites.Client, fn conn ->
      send(self(), {:req, conn.method, conn.request_path, conn.req_headers})
      Req.Test.json(conn, %{"name" => "s1", "status" => "running"})
    end)

    :ok
  end

  test "create_sprite/1 POSTs name + bearer auth" do
    assert {:ok, %{"name" => "s1"}} = Client.create_sprite("s1")
    assert_received {:req, "POST", "/v1/sprites", headers}
    assert {"authorization", "Bearer tkn"} in headers
  end

  test "returns {:error, _} when SPRITES_TOKEN is unset" do
    Application.put_env(:legend, :sprites_token, nil)
    assert {:error, msg} = Client.create_sprite("s1")
    assert msg =~ "SPRITES_TOKEN"
  end
end
