defmodule Legend.Harnesses.OpenClawTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.OpenClaw

  test "definition: terminal-only, resumable" do
    d = OpenClaw.definition()
    assert d.id == "openclaw"
    assert d.name == "OpenClaw"
    assert d.transports == [:terminal]
    assert d.resumable
  end

  test "build_command runs the local chat TUI with a pinned session as a :pty spec" do
    spec = OpenClaw.build_command(%{})
    assert spec.io == :pty
    assert spec.cmd == "openclaw"
    assert spec.args == ["chat", "--session", "main"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command seeds the initial prompt with --message" do
    spec = OpenClaw.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.args == ["chat", "--session", "main", "--message", "do the thing"]
  end

  test "build_command resume reuses the pinned session without a message" do
    spec =
      OpenClaw.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})

    assert spec.args == ["chat", "--session", "main"]
    refute "ignored" in spec.args
    refute "--message" in spec.args
  end

  test "does not implement the Acp behaviour" do
    refute function_exported?(OpenClaw, :acp_command, 1)
  end

  test "provision targets openclaw for terminal" do
    p = OpenClaw.provision(:terminal)
    assert p.detect.cmd == "openclaw"
    assert "--version" in p.detect.args
    assert Enum.join(p.install.args, " ") =~ "openclaw"
  end
end
