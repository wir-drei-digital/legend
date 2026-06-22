defmodule Legend.Harnesses.GeminiTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.Gemini

  test "definition: terminal-first, acp second, resumable" do
    d = Gemini.definition()
    assert d.id == "gemini"
    assert d.name == "Gemini"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt with -i as a :pty spec" do
    spec = Gemini.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "gemini"
    assert spec.args == ["-i", "do the thing"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare REPL" do
    assert %{args: []} = Gemini.build_command(%{})
  end

  test "build_command resume uses `-r latest` and drops instructions" do
    spec =
      Gemini.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})

    assert spec.args == ["-r", "latest"]
    refute "ignored" in spec.args
  end

  test "acp_command appends --acp to the same binary as a :pipes spec" do
    spec = Gemini.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "gemini"
    assert spec.args == ["--acp"]
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets gemini for both transports" do
    for t <- [:terminal, :acp] do
      p = Gemini.provision(t)
      assert p.detect.cmd == "gemini"
      assert "--version" in p.detect.args
      assert Enum.join(p.install.args, " ") =~ "@google/gemini-cli"
    end
  end
end
