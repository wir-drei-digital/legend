defmodule Legend.Harnesses.ClaudeCode do
  @moduledoc "Terminal harness for Anthropic's Claude Code CLI."

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal
  @behaviour Legend.Core.Harness.Acp

  alias Legend.Core.Harness.Definition
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Runtime.CommandSpec

  @impl Legend.Core.Harness
  def definition do
    %Definition{
      id: "claude_code",
      name: "Claude Code",
      description: "Anthropic's agentic coding CLI",
      transports: [:acp, :terminal],
      resumable: true
    }
  end

  @impl Legend.Core.Harness
  def provision do
    %{
      detect: %CommandSpec{cmd: "claude", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "curl -fsSL https://claude.ai/install.sh | sh"],
        io: :pipes
      }
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:claude_code, "claude")

    %CommandSpec{
      cmd: cmd,
      args:
        args ++
          primer_args(opts) ++ mcp_args(opts) ++ session_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  @impl Legend.Core.Harness.Acp
  def acp_command(opts) do
    [cmd | args] = configured_command(:claude_code_acp, "claude-code-acp")
    %CommandSpec{cmd: cmd, args: args, env: opts[:env] || %{}, io: :pipes}
  end

  defp primer_args(opts) do
    case Terminal.primers(opts) do
      [] -> []
      primers -> ["--append-system-prompt", Enum.join(primers, "\n\n")]
    end
  end

  defp mcp_args(%{mcp: %{url: url, token: token}}) do
    config =
      Jason.encode!(%{
        mcpServers: %{
          legend: %{type: "http", url: url, headers: %{Authorization: "Bearer #{token}"}}
        }
      })

    # "mcp__legend" is a server-level allow rule: every tool from this server.
    ["--mcp-config", config, "--allowed-tools", "mcp__legend"]
  end

  defp mcp_args(_opts), do: []

  # Our session id IS the agent's conversation id: pinned at fresh launch,
  # reopened on resume (per the Terminal resume contract).
  defp session_args(%{session_id: id, mode: :resume}) when is_binary(id), do: ["--resume", id]
  defp session_args(%{session_id: id}) when is_binary(id), do: ["--session-id", id]
  defp session_args(_opts), do: []

  # The resumed conversation already contains the instructions — never re-send.
  defp instruction_args(%{mode: :resume}), do: []

  # Trailing positional arg = initial prompt in Claude Code's interactive mode.
  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> [text]
    end
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
