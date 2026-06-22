defmodule Legend.Harnesses.Gemini do
  @moduledoc """
  Harness for Google's Gemini CLI. Native ACP (`gemini --acp`, same binary) plus
  the interactive `gemini` REPL. Default `:terminal` (authenticate via Google
  login / GEMINI_API_KEY in the agent's own store); switch to `:acp` for the
  rich UI. Legend stores no credential.

  The initial prompt seeds the interactive REPL via `-i` (`--prompt-interactive`),
  NOT `-p` (which forces a headless one-shot that exits). Terminal resume is
  best-effort — Gemini resumes by `latest`/index, not a pinnable id — so Legend
  uses `gemini -r latest` (most-recent session for the project). Signal-bus MCP
  and primers are delivered only over ACP; in terminal mode Gemini uses its own
  GEMINI.md/settings (out of Phase 3 scope).

  Known upstream risks (validate at live bring-up): ACP mode may not honor
  GEMINI_API_KEY non-interactively (google-gemini/gemini-cli#10855) and `--acp`
  has hung when spawned from non-TTY contexts (#22782) — pre-establish auth.
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
      id: "gemini",
      name: "Gemini",
      description: "Google's Gemini coding CLI",
      transports: [:terminal, :acp],
      resumable: true
    }
  end

  @impl Legend.Core.Harness
  def provision(_transport) do
    %{
      detect: %CommandSpec{cmd: "gemini", args: ["--version"], io: :pipes},
      install: %CommandSpec{
        cmd: "sh",
        args: ["-lc", "npm i -g @google/gemini-cli"],
        io: :pipes
      }
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:gemini, "gemini")

    %CommandSpec{
      cmd: cmd,
      args: args ++ session_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  @impl Legend.Core.Harness.Acp
  def acp_command(opts) do
    [cmd | args] = configured_command(:gemini, "gemini")
    %CommandSpec{cmd: cmd, args: args ++ ["--acp"], env: opts[:env] || %{}, io: :pipes}
  end

  # `-r latest` reopens the most-recent session for the project. Fresh launch
  # takes no session flag (Gemini has no pin-at-create id).
  defp session_args(%{mode: :resume}), do: ["-r", "latest"]
  defp session_args(_opts), do: []

  defp instruction_args(%{mode: :resume}), do: []

  # `-i`/`--prompt-interactive`: submit the prompt then stay interactive.
  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> ["-i", text]
    end
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
