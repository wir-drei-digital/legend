defmodule Legend.Harnesses.Codex do
  @moduledoc """
  Harness for OpenAI's Codex CLI. Two transports: `:terminal` (the `codex` TUI,
  default — authenticate via `codex login` in the PTY) and `:acp` (the separate
  `@zed-industries/codex-acp` adapter — the rich structured UI). Auth lives in
  the agent's own store (~/.codex); Legend stores no credential.

  Terminal resume is best-effort: Codex has no pin-at-create flag (unlike Claude
  Code's --session-id), so Legend cannot pin its own id as the conversation id —
  resume uses `codex resume --last` (the most-recent session in the cwd). The
  signal-bus MCP and library/messaging primers are delivered only over ACP
  (session/new mcpServers + first prompt); in terminal mode Codex uses its own
  AGENTS.md/config (out of Phase 3 scope). The initial-prompt instructions ARE
  delivered in both modes.
  """

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal
  @behaviour Legend.Core.Harness.Acp

  alias Legend.Core.Harness.Definition
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Runtime.CommandSpec

  @impl Legend.Core.Harness
  def definition do
    %Definition{
      id: "codex",
      name: "Codex",
      description: "OpenAI's Codex coding CLI",
      transports: [:terminal, :acp],
      resumable: true
    }
  end

  @impl Legend.Core.Harness
  def provision(:acp) do
    %{
      detect: %CommandSpec{cmd: "codex-acp", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "npm i -g @zed-industries/codex-acp"],
        io: :pipes
      }
    }
  end

  def provision(_terminal) do
    %{
      detect: %CommandSpec{cmd: "codex", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "npm i -g @openai/codex"],
        io: :pipes
      }
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:codex, "codex")

    %CommandSpec{
      cmd: cmd,
      args: args ++ session_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  @impl Legend.Core.Harness.Acp
  def acp_command(opts) do
    [cmd | args] = configured_command(:codex_acp, "codex-acp")
    %CommandSpec{cmd: cmd, args: args, env: opts[:env] || %{}, io: :pipes}
  end

  # `codex resume --last` reopens the most-recent session in the cwd. Fresh
  # launch takes no session flags (Codex mints its own id; we never pin it).
  defp session_args(%{mode: :resume}), do: ["resume", "--last"]
  defp session_args(_opts), do: []

  # The resumed conversation already contains the instructions — never re-send.
  defp instruction_args(%{mode: :resume}), do: []

  # Trailing positional arg seeds Codex's interactive TUI (NOT `codex exec`,
  # which is the headless run-and-exit mode).
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
