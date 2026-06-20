defmodule Legend.Core.Agents.TranscriptTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Agents.{AcpTimeline, Transcript}

  test "AcpTimeline upserts by id and bumps seq" do
    t = AcpTimeline.new()
    {t, [a]} = Transcript.append(t, %{"id" => "msg-1", "type" => "message", "text" => "hi"})
    assert a["seq"] == 1
    {t, [b]} = Transcript.append(t, %{"id" => "msg-1", "type" => "message", "text" => "hi there"})
    assert b["seq"] == 2
    {items, cursor} = Transcript.snapshot(t)
    assert cursor == 2
    assert [%{"id" => "msg-1", "text" => "hi there"}] = items
  end
end
