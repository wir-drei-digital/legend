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

  # FP-1: a partial resolved-permission update must MERGE onto the existing full
  # item, preserving title/options while overwriting resolved/selected + seq.
  test "AcpTimeline merges a partial update onto an existing item" do
    t = AcpTimeline.new()

    {t, [full]} =
      Transcript.append(t, %{
        "id" => "perm-1",
        "type" => "permission",
        "title" => "Run command",
        "command" => "ls -la",
        "options" => [%{"optionId" => "allow", "name" => "Allow"}],
        "resolved" => false
      })

    assert full["seq"] == 1

    {t, [merged]} =
      Transcript.append(t, %{
        "id" => "perm-1",
        "type" => "permission",
        "resolved" => true,
        "selected" => "allow"
      })

    # Preserved from the original item.
    assert merged["title"] == "Run command"
    assert merged["command"] == "ls -la"
    assert merged["options"] == [%{"optionId" => "allow", "name" => "Allow"}]
    # Overwritten by the partial update.
    assert merged["resolved"] == true
    assert merged["selected"] == "allow"
    assert merged["seq"] == 2

    {[item], cursor} = Transcript.snapshot(t)
    assert cursor == 2
    assert item["title"] == "Run command" and item["resolved"] == true
  end
end
