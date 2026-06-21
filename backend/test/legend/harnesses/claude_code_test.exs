defmodule Legend.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.ClaudeCode

  test "acp_command returns a :pipes spec for the adapter" do
    spec = ClaudeCode.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "claude-code-acp"
    assert spec.env["FOO"] == "bar"
  end

  test "provision/1 targets claude for terminal, claude-code-acp for acp" do
    assert ClaudeCode.provision(:terminal).detect.cmd == "claude"

    acp = ClaudeCode.provision(:acp)
    assert acp.detect.cmd == "claude-code-acp"
    assert acp.detect.io == :pipes
    assert Enum.join(acp.install.args, " ") =~ "@zed-industries/claude-code-acp"
    assert acp.install.io == :pipes
  end
end
