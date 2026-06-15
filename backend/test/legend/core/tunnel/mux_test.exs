defmodule Legend.Core.Tunnel.MuxTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  test "encode/decode round-trips a DATA frame" do
    frame = %Frame{type: :data, stream_id: 7, payload: "hello"}
    {:ok, [decoded], ""} = Mux.decode(Mux.encode(frame))
    assert decoded == frame
  end

  test "encodes each type with the right tag byte" do
    assert <<1, 0::32, 0::32>> = Mux.encode(%Frame{type: :open, stream_id: 0, payload: ""})
    assert <<3, 9::32, 0::32>> = Mux.encode(%Frame{type: :close, stream_id: 9, payload: ""})
    assert <<4, 9::32, 4::32, 1024::32>> = Mux.encode(Mux.window(9, 1024))
  end

  test "decode/1 returns multiple frames and leftover bytes" do
    buf =
      Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""}) <>
        Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ab"})

    {:ok, frames, ""} = Mux.decode(buf)

    assert [%Frame{type: :open, stream_id: 1}, %Frame{type: :data, stream_id: 1, payload: "ab"}] =
             frames
  end

  test "decode/1 keeps an incomplete trailing frame in the leftover buffer" do
    full = Mux.encode(%Frame{type: :data, stream_id: 1, payload: "abcd"})
    {head, tail} = String.split_at(full, byte_size(full) - 2)
    assert {:ok, [], ^head} = Mux.decode(head)
    {:ok, [%Frame{payload: "abcd"}], ""} = Mux.decode(head <> tail)
  end

  test "window/2 builds a WINDOW frame carrying the credit" do
    assert %Frame{type: :window, stream_id: 3, payload: <<512::32>>} = Mux.window(3, 512)

    assert {:window, 3, 512} =
             Mux.parse_window(%Frame{type: :window, stream_id: 3, payload: <<512::32>>})
  end

  # --- Task 6: frame-size cap ---

  test "round-trips a frame and reports leftover" do
    bin = Mux.encode(%Frame{type: :data, stream_id: 7, payload: "hi"})
    assert {:ok, [%Frame{type: :data, stream_id: 7, payload: "hi"}], "x"} = Mux.decode(bin <> "x")
  end

  test "an incomplete frame is left in the buffer" do
    <<head::binary-size(5), _::binary>> =
      Mux.encode(%Frame{type: :data, stream_id: 1, payload: "abc"})

    assert {:ok, [], ^head} = Mux.decode(head)
  end

  test "a frame whose declared length exceeds the cap is rejected" do
    oversized = <<2, 1::32, Mux.max_frame_payload() + 1::32>>
    assert {:error, :frame_too_large} = Mux.decode(oversized)
  end
end
