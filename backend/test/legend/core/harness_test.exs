defmodule Legend.Core.HarnessTest do
  use ExUnit.Case, async: true

  test "ClaudeCode advertises acp + terminal, acp first" do
    assert Legend.Harnesses.ClaudeCode.definition().transports == [:acp, :terminal]
  end

  test "Hermes is terminal-only" do
    assert Legend.Harnesses.Hermes.definition().transports == [:terminal]
  end
end
