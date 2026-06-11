defmodule Legend.Harnesses.ClaudeCode do
  @moduledoc "Terminal harness for Anthropic's Claude Code CLI."

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal

  alias Legend.Core.Harness.Definition
  alias Legend.Core.Runtime.CommandSpec

  @impl Legend.Core.Harness
  def definition do
    %Definition{
      id: "claude_code",
      name: "Claude Code",
      description: "Anthropic's agentic coding CLI",
      kind: :terminal
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:claude_code, "claude")

    %CommandSpec{
      cmd: cmd,
      args: args,
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
