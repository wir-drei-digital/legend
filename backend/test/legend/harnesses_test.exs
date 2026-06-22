defmodule Legend.HarnessesTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Runtime.CommandSpec

  setup do
    original = Application.get_env(:legend, :harness_commands, [])
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)
    :ok
  end

  test "claude_code definition and default command" do
    assert %Legend.Core.Harness.Definition{id: "claude_code", transports: [:acp, :terminal]} =
             Legend.Harnesses.ClaudeCode.definition()

    assert %CommandSpec{cmd: "claude", args: [], io: :pty, env: env} =
             Legend.Harnesses.ClaudeCode.build_command(%{})

    assert env["TERM"] == "xterm-256color"
  end

  test "hermes definition and default command" do
    assert %Legend.Core.Harness.Definition{id: "hermes", transports: [:terminal]} =
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
    assert ids == ["claude_code", "codex", "gemini", "hermes"]
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

  describe "messaging wiring" do
    @opts %{
      library: %{path: "/lib", primer: "LIB PRIMER"},
      mcp: %{url: "http://localhost:4100/api/mcp", token: "tok123"},
      messaging: %{primer: "MSG PRIMER", instructions: nil}
    }

    test "claude_code registers the MCP server and allows its tools" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)

      mcp_index = Enum.find_index(spec.args, &(&1 == "--mcp-config"))
      assert mcp_index
      config = Jason.decode!(Enum.at(spec.args, mcp_index + 1))
      assert config["mcpServers"]["legend"]["url"] == "http://localhost:4100/api/mcp"
      assert config["mcpServers"]["legend"]["headers"]["Authorization"] == "Bearer tok123"

      allowed_index = Enum.find_index(spec.args, &(&1 == "--allowed-tools"))
      assert Enum.at(spec.args, allowed_index + 1) == "mcp__legend"
    end

    test "claude_code joins library and messaging primers in one system prompt" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)
      index = Enum.find_index(spec.args, &(&1 == "--append-system-prompt"))
      prompt = Enum.at(spec.args, index + 1)
      assert prompt =~ "LIB PRIMER"
      assert prompt =~ "MSG PRIMER"
    end

    test "claude_code passes instructions as the trailing positional prompt" do
      opts = put_in(@opts, [:messaging, :instructions], "do the thing")
      spec = Legend.Harnesses.ClaudeCode.build_command(opts)
      assert List.last(spec.args) == "do the thing"

      # Without instructions there is no trailing prompt.
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)
      refute List.last(spec.args) == "do the thing"
    end

    test "hermes passes instructions positionally and ignores mcp opts (env-only fallback)" do
      opts = put_in(@opts, [:messaging, :instructions], "take over")
      spec = Legend.Harnesses.Hermes.build_command(opts)
      assert List.last(spec.args) == "take over"
      refute "--mcp-config" in spec.args
    end

    test "default nudge line names the sender and read_messages" do
      line = Legend.Core.Harness.Terminal.nudge_line(Legend.Harnesses.ClaudeCode, 2, "hermes")
      assert line =~ "2 unread"
      assert line =~ "hermes"
      assert line =~ "read_messages"
    end

    test "nudge_line strips control chars from the sender label" do
      line =
        Legend.Core.Harness.Terminal.nudge_line(
          Legend.Harnesses.ClaudeCode,
          1,
          "evil\rrm -rf ~\r\e[2J"
        )

      refute line =~ "\r"
      refute line =~ "\e"
      refute line =~ "\n"
      assert line =~ "read_messages"
    end
  end

  describe "resume wiring" do
    @resume_opts %{
      library: %{path: "/lib", primer: ""},
      messaging: %{primer: "", instructions: "do the thing"},
      session_id: "11111111-2222-3333-4444-555555555555"
    }

    test "claude_code is resumable, hermes is not" do
      assert Legend.Harnesses.ClaudeCode.definition().resumable == true
      assert Legend.Harnesses.Hermes.definition().resumable == false
    end

    test "claude_code pins the conversation id on fresh launch" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.put(@resume_opts, :mode, :fresh))
      index = Enum.find_index(spec.args, &(&1 == "--session-id"))
      assert index
      assert Enum.at(spec.args, index + 1) == "11111111-2222-3333-4444-555555555555"
      # Instructions still delivered on fresh launch.
      assert List.last(spec.args) == "do the thing"
    end

    test "claude_code mode defaults to fresh when absent" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@resume_opts)
      assert "--session-id" in spec.args
      refute "--resume" in spec.args
    end

    test "claude_code resumes the conversation and omits instructions" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.put(@resume_opts, :mode, :resume))
      index = Enum.find_index(spec.args, &(&1 == "--resume"))
      assert index
      assert Enum.at(spec.args, index + 1) == "11111111-2222-3333-4444-555555555555"
      refute "--session-id" in spec.args
      # The conversation already contains the instructions — never re-send.
      refute "do the thing" in spec.args
    end

    test "claude_code without a session_id emits no session flags" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.delete(@resume_opts, :session_id))
      refute "--session-id" in spec.args
      refute "--resume" in spec.args
    end

    test "hermes ignores mode (resume degrades to fresh)" do
      fresh = Legend.Harnesses.Hermes.build_command(Map.put(@resume_opts, :mode, :fresh))
      resumed = Legend.Harnesses.Hermes.build_command(Map.put(@resume_opts, :mode, :resume))
      assert fresh.args == resumed.args
      refute "--resume" in resumed.args
    end
  end

  describe "setup seam" do
    test "setup_for/1 on a harness without the callbacks is not_applicable" do
      assert %Legend.Core.Harness.Setup{status: :not_applicable} =
               Legend.Core.Harness.setup_for(Legend.Harnesses.ClaudeCode)
    end

    test "setup_for/1 on a harness exporting setup/0 calls through" do
      defmodule WithSetup do
        @behaviour Legend.Core.Harness

        @impl Legend.Core.Harness
        def definition,
          do: %Legend.Core.Harness.Definition{
            id: "with_setup",
            name: "With Setup",
            transports: [:terminal]
          }

        @impl Legend.Core.Harness
        def setup,
          do: %Legend.Core.Harness.Setup{status: :missing, summary: "do the thing"}
      end

      assert %Legend.Core.Harness.Setup{status: :missing, summary: "do the thing"} =
               Legend.Core.Harness.setup_for(WithSetup)
    end

    test "registry entries pair modules with definitions" do
      entries = Legend.Core.Harness.Registry.entries()

      assert {Legend.Harnesses.ClaudeCode, %Legend.Core.Harness.Definition{id: "claude_code"}} =
               Enum.find(entries, fn {mod, _} -> mod == Legend.Harnesses.ClaudeCode end)
    end
  end
end
