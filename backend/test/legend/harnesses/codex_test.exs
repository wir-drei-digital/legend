defmodule Legend.Harnesses.CodexTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.Codex

  test "definition: terminal-first, acp second, resumable" do
    d = Codex.definition()
    assert d.id == "codex"
    assert d.name == "Codex"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt positionally as a :pty spec" do
    spec = Codex.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "codex"
    assert List.last(spec.args) == "do the thing"
    refute "resume" in spec.args
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare TUI" do
    assert %{args: []} = Codex.build_command(%{})
  end

  test "build_command resume uses `resume --last` and drops instructions" do
    spec =
      Codex.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})

    assert spec.args == ["resume", "--last"]
    refute "ignored" in spec.args
  end

  test "caller env is merged over TERM" do
    spec = Codex.build_command(%{env: %{"FOO" => "bar"}})
    assert spec.env == %{"TERM" => "xterm-256color", "FOO" => "bar"}
  end

  test "acp_command returns a :pipes spec for the codex-acp adapter" do
    spec = Codex.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "codex-acp"
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets codex for terminal and codex-acp for acp" do
    term = Codex.provision(:terminal)
    assert term.detect.cmd == "codex"
    assert "--version" in term.detect.args
    assert Enum.join(term.install.args, " ") =~ "@openai/codex"

    acp = Codex.provision(:acp)
    assert acp.detect.cmd == "codex-acp"
    assert acp.detect.io == :pipes
    assert Enum.join(acp.install.args, " ") =~ "@zed-industries/codex-acp"
    assert acp.install.io == :pipes
  end
end
