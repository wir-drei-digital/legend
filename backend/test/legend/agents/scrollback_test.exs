defmodule Legend.Agents.ScrollbackTest do
  use ExUnit.Case, async: true

  alias Legend.Agents.Scrollback

  test "appends and renders in order" do
    sb = Scrollback.new() |> Scrollback.append("hello ") |> Scrollback.append("world")
    assert Scrollback.to_binary(sb) == "hello world"
  end

  test "drops oldest chunks beyond max_bytes" do
    sb =
      Scrollback.new(10)
      |> Scrollback.append("aaaa")
      |> Scrollback.append("bbbb")
      |> Scrollback.append("cccc")

    assert Scrollback.to_binary(sb) == "bbbbcccc"
  end

  test "always keeps the newest chunk even if it alone exceeds max_bytes" do
    sb = Scrollback.new(4) |> Scrollback.append("aa") |> Scrollback.append("bbbbbbbb")
    assert Scrollback.to_binary(sb) == "bbbbbbbb"
  end

  test "empty buffer renders empty binary" do
    assert Scrollback.to_binary(Scrollback.new()) == ""
  end

  test "evicts a previously kept oversized chunk once newer data arrives" do
    sb =
      Scrollback.new(4)
      |> Scrollback.append("aa")
      |> Scrollback.append("bbbbbbbb")
      |> Scrollback.append("c")

    assert Scrollback.to_binary(sb) == "c"
    assert sb.bytes == 1
  end
end
