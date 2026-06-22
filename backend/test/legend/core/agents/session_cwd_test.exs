defmodule Legend.Core.Agents.SessionCwdTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Agents.Session

  describe "normalize_cwd/2 — local runtime" do
    test "expands a leading ~/" do
      assert Session.normalize_cwd("~/proj", "local_pty") ==
               Path.join(System.user_home!(), "proj")
    end

    test "expands a bare ~" do
      assert Session.normalize_cwd("~", "local_pty") == System.user_home!()
    end

    test "strips a trailing slash" do
      assert Session.normalize_cwd("/Users/x/proj/", "local_pty") == "/Users/x/proj"
    end

    test "collapses . and .. in absolute paths" do
      assert Session.normalize_cwd("/a/b/../c", "local_pty") == "/a/c"
    end

    test "trims surrounding whitespace" do
      assert Session.normalize_cwd("  /a/b  ", "local_pty") == "/a/b"
    end
  end

  describe "normalize_cwd/2 — remote runtime" do
    test "keeps a sandbox path opaque, stripping only the trailing slash" do
      assert Session.normalize_cwd("/root/work/", "sprites") == "/root/work"
    end

    test "does not host-expand ~ for remote" do
      assert Session.normalize_cwd("~/work", "sprites") == "~/work"
    end
  end

  describe "normalize_cwd/2 — blank" do
    test "nil stays nil" do
      assert Session.normalize_cwd(nil, "local_pty") == nil
    end

    test "whitespace-only becomes nil" do
      assert Session.normalize_cwd("   ", "local_pty") == nil
    end
  end
end
