defmodule Legend.Harnesses.OpenCode do
  @moduledoc """
  Harness for sst's opencode. Native ACP (`opencode acp`, same binary) plus the
  interactive `opencode` TUI. Default `:terminal` (authenticate via
  `opencode auth login` in the PTY); switch to `:acp` for the rich UI. Legend
  stores no credential.

  The initial prompt is seeded with `--prompt` (the TUI positional arg is a
  project dir, not a prompt). KNOWN LIMITATION: `--prompt` only PRE-FILLS the
  input box and does not auto-submit (sst/opencode#3937), so a delegated
  opencode session shows its task awaiting a manual Enter. Terminal resume uses
  `--continue` (last session). Signal-bus MCP and primers are delivered only
  over ACP; in terminal mode opencode uses its own AGENTS.md/opencode.json
  (out of Phase 3 scope).
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
      id: "opencode",
      name: "OpenCode",
      description: "sst's opencode coding agent",
      transports: [:terminal, :acp],
      resumable: true
    }
  end

  @impl Legend.Core.Harness
  def provision(_transport) do
    %{
      detect: %CommandSpec{cmd: "opencode", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "npm i -g opencode-ai"],
        io: :pipes
      }
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:opencode, "opencode")

    %CommandSpec{
      cmd: cmd,
      args: args ++ session_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  @impl Legend.Core.Harness.Acp
  def acp_command(opts) do
    [cmd | args] = configured_command(:opencode, "opencode")
    %CommandSpec{cmd: cmd, args: args ++ ["acp"], env: opts[:env] || %{}, io: :pipes}
  end

  # `--continue` reopens the last session. Fresh launch takes no session flag.
  defp session_args(%{mode: :resume}), do: ["--continue"]
  defp session_args(_opts), do: []

  defp instruction_args(%{mode: :resume}), do: []

  # `--prompt` pre-fills the TUI input (does not auto-submit; see moduledoc).
  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> ["--prompt", text]
    end
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
