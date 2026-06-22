defmodule Legend.Harnesses.OpenCodeTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.OpenCode

  test "definition: terminal-first, acp second, resumable" do
    d = OpenCode.definition()
    assert d.id == "opencode"
    assert d.name == "OpenCode"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt with --prompt as a :pty spec" do
    spec = OpenCode.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "opencode"
    assert spec.args == ["--prompt", "do the thing"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare TUI" do
    assert %{args: []} = OpenCode.build_command(%{})
  end

  test "build_command resume uses --continue and drops instructions" do
    spec =
      OpenCode.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})

    assert spec.args == ["--continue"]
    refute "ignored" in spec.args
  end

  test "acp_command uses the `acp` subcommand on the same binary as a :pipes spec" do
    spec = OpenCode.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "opencode"
    assert spec.args == ["acp"]
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets opencode for both transports" do
    for t <- [:terminal, :acp] do
      p = OpenCode.provision(t)
      assert p.detect.cmd == "opencode"
      assert "--version" in p.detect.args
      assert Enum.join(p.install.args, " ") =~ "opencode-ai"
    end
  end
end
