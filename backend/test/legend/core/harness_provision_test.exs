defmodule Legend.Core.HarnessProvisionTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Harness
  alias Legend.Core.Runtime.CommandSpec

  test "provision_for/1 returns nil for a harness without provision/0" do
    defmodule Bare do
      @behaviour Legend.Core.Harness
      def definition,
        do: %Legend.Core.Harness.Definition{id: "bare", name: "Bare", kind: :terminal}
    end

    assert Harness.provision_for(Bare) == nil
  end

  test "Claude Code declares a detect + install provision spec" do
    assert %{detect: %CommandSpec{} = detect, install: %CommandSpec{}} =
             Harness.provision_for(Legend.Harnesses.ClaudeCode)

    assert detect.cmd == "claude"
    assert "--version" in detect.args
  end
end
