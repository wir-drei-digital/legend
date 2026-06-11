defmodule Legend.HarnessesTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Runtime.CommandSpec

  setup do
    original = Application.get_env(:legend, :harness_commands, [])
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)
    :ok
  end

  test "claude_code definition and default command" do
    assert %Legend.Core.Harness.Definition{id: "claude_code", kind: :terminal} =
             Legend.Harnesses.ClaudeCode.definition()

    assert %CommandSpec{cmd: "claude", args: [], io: :pty, env: env} =
             Legend.Harnesses.ClaudeCode.build_command(%{})

    assert env["TERM"] == "xterm-256color"
  end

  test "hermes definition and default command" do
    assert %Legend.Core.Harness.Definition{id: "hermes", kind: :terminal} =
             Legend.Harnesses.Hermes.definition()

    assert %CommandSpec{cmd: "hermes", args: []} = Legend.Harnesses.Hermes.build_command(%{})
  end

  test "configured command line is whitespace-split into cmd and args" do
    Application.put_env(:legend, :harness_commands, hermes: "hermes --profile work")

    assert %CommandSpec{cmd: "hermes", args: ["--profile", "work"]} =
             Legend.Harnesses.Hermes.build_command(%{})
  end

  test "caller env overrides are merged in" do
    assert %CommandSpec{env: %{"FOO" => "bar", "TERM" => "xterm-256color"}} =
             Legend.Harnesses.ClaudeCode.build_command(%{env: %{"FOO" => "bar"}})
  end

  test "both built-ins are registered" do
    ids = Legend.Core.Harness.Registry.list() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["claude_code", "hermes"]
  end

  describe "library primer delivery" do
    @library %{path: "/lib/root", primer: "Use the library."}

    test "claude_code appends --append-system-prompt when library opts present" do
      assert %CommandSpec{args: args} =
               Legend.Harnesses.ClaudeCode.build_command(%{library: @library})

      assert ["--append-system-prompt", "Use the library."] = Enum.take(args, -2)
    end

    test "claude_code emits no primer args without library opts" do
      assert %CommandSpec{args: []} = Legend.Harnesses.ClaudeCode.build_command(%{})
    end

    test "hermes delivers the primer only when a flag template is configured" do
      assert %CommandSpec{args: []} = Legend.Harnesses.Hermes.build_command(%{library: @library})

      Application.put_env(
        :legend,
        :harness_commands,
        hermes: "hermes",
        hermes_primer_flag: "--system-prompt"
      )

      assert %CommandSpec{args: args} =
               Legend.Harnesses.Hermes.build_command(%{library: @library})

      assert ["--system-prompt", "Use the library."] = Enum.take(args, -2)
    end
  end
end
