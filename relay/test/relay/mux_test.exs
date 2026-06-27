defmodule Relay.MuxTest do
  use ExUnit.Case, async: true
  alias Relay.Mux
  alias Relay.Mux.Frame

  test "encode/decode round-trips a DATA frame" do
    f = %Frame{type: :data, stream_id: 7, payload: "hello"}
    assert {:ok, [decoded], ""} = Mux.decode(Mux.encode(f))
    assert decoded == f
  end

  test "decode handles a partial buffer (returns the remainder)" do
    bin = Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})
    {head, tail} = String.split_at(bin, 4)
    assert {:ok, [], ^head} = Mux.decode(head)
    assert {:ok, [%Frame{type: :open, stream_id: 1}], ""} = Mux.decode(head <> tail)
  end

  test "frame type tags match the wire contract" do
    assert <<1, _::binary>> = Mux.encode(%Frame{type: :open, stream_id: 0})
    assert <<2, _::binary>> = Mux.encode(%Frame{type: :data, stream_id: 0, payload: "x"})
    assert <<3, _::binary>> = Mux.encode(%Frame{type: :close, stream_id: 0})
  end
end
