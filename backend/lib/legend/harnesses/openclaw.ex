defmodule Legend.Harnesses.OpenClaw do
  @moduledoc """
  Terminal harness for openclaw's local TUI. Spawns `openclaw chat` (alias for
  `openclaw tui --local` — the standalone embedded runtime), NOT `openclaw acp`
  (a Gateway bridge that needs a separately-running OpenClaw Gateway). ACP is
  intentionally not offered for this reason.

  Requires a one-time `openclaw setup` (or `openclaw onboard`) + model auth in
  the agent's own config before first use; Legend stores no credential. A stable
  session key (`--session main`) is pinned so resume reuses it; the initial
  prompt is seeded with `--message`. OpenClaw's own signal-bus MCP/primers are
  config-file based and out of Phase 3 scope.
  """

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal

  alias Legend.Core.Harness.Definition
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Runtime.CommandSpec

  @impl Legend.Core.Harness
  def definition do
    %Definition{
      id: "openclaw",
      name: "OpenClaw",
      description: "OpenClaw local agent TUI",
      transports: [:terminal],
      resumable: true
    }
  end

  @impl Legend.Core.Harness
  def provision(_transport) do
    %{
      detect: %CommandSpec{cmd: "openclaw", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "npm i -g openclaw@latest"],
        io: :pipes
      }
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:openclaw, "openclaw")

    %CommandSpec{
      cmd: cmd,
      args: args ++ ["chat", "--session", "main"] ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  # Resume reuses the pinned session key; never re-send the instructions.
  defp instruction_args(%{mode: :resume}), do: []

  # `--message` sends the first turn, then stays interactive.
  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> ["--message", text]
    end
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
