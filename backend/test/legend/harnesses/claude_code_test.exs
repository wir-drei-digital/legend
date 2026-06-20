defmodule Legend.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: true

  test "acp_command returns a :pipes spec for the adapter" do
    spec = Legend.Harnesses.ClaudeCode.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "claude-code-acp"
    assert spec.env["FOO"] == "bar"
  end
end
