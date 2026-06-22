# ACP Rich Sessions — Phase 3 (Codex + Gemini + OpenCode + OpenClaw) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four new agent harnesses — Codex, Gemini, OpenCode (terminal + rich ACP, switchable) and OpenClaw (terminal-only) — reusing the Phase 1/2 ACP spine, rich UI, channel, and `:pipes` runtime unchanged.

**Architecture:** Each new agent is a thin harness module implementing `Legend.Core.Harness` (+ `Terminal`, + `Acp` for the three dual-transport ones). The protocol engine (`Acp.Connection`), timeline, channel, rich Svelte surface, provisioning loop, transport switching, and conversation-id capture are all shared and agent-agnostic — no changes needed. Auth is each CLI's own login flow in the PTY (terminal-first); Legend stores **no** credential. The frontend already renders harnesses, the transport picker, and the rich/term toggle generically, so only the hardcoded terminal-first hint copy is generalized.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 (backend harness modules + config + ExUnit); SvelteKit 2 / Svelte 5 runes (one frontend copy change); Markdown (spec + ARCHITECTURE docs). External agent CLIs are installed by the operator / provisioning, never bundled.

## Global Constraints

- **Clean-over-compat:** early-stage project; prefer clean code over back-compat shims. No new mix deps (these harnesses are pure Elixir; the agents are external CLIs).
- **Do NOT stage or commit pre-existing uncommitted changes** the user is deliberately keeping: `backend/mix.exs`, `backend/mix.lock`, and the untracked `backend/.credo.exs` and `AGENTS.md`. Each task stages **only the files it creates/modifies, by explicit path** — never `git add -A` / `git add .` / `git add backend`.
- **Registry ids stay strings.** Never `String.to_atom/1` on user input. New harness ids are the literal strings `"codex"`, `"gemini"`, `"opencode"`, `"openclaw"`.
- **No stored credentials.** Auth is the agent CLI's own login flow in the PTY (terminal-first). No API-key entry UI, no secrets in Settings.
- **Transport ordering encodes the default.** The three dual-transport harnesses use `transports: [:terminal, :acp]` (terminal-first auth — `default_transport/2` returns the first entry for local and forces `:terminal` for provisioning runtimes). OpenClaw is `transports: [:terminal]`.
- **Terminal-mode scope (intentional):** the new terminal harnesses deliver the **initial-prompt instructions** (`messaging.instructions`) via each CLI's documented initial-prompt mechanism, but do **NOT** deliver the library/messaging **primers** or register the **signal-bus MCP** in terminal mode (these CLIs configure context/MCP via files like `AGENTS.md`/`GEMINI.md`/`opencode.json`, not per-launch flags). Primers + signal bus work over **ACP** (delivered generically by `Acp.Connection` via `session/new` `mcpServers` + first prompt). This is the same conservative posture as the Hermes terminal harness.
- **No PTY injection.** Instructions are delivered as launch **argv** (like ClaudeCode's positional prompt), never written to `runtime.write/2`. Nothing new reaches `runtime.write/2`, so no new sanitization is required (the existing `nudge_line/3` sanitization is untouched).
- **Each backend task keeps the whole suite green.** Registering a harness changes the two harness-list assertions (`test/legend/harnesses_test.exs` ~line 43 and `test/legend_web/controllers/harness_controller_test.exs` ~line 9). Each task updates BOTH to its **cumulative sorted id list** (exact lists given per task).
- **Finish discipline:** run `cd backend && mix precommit` (compile --warnings-as-errors + format + test) before a backend task is done; `cd frontend && bun run check` before the frontend task is done.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `backend/lib/legend/harnesses/codex.ex` *(create)* | Codex harness: `[:terminal, :acp]`, `codex` TUI + `codex-acp` adapter, provisioning |
| `backend/lib/legend/harnesses/gemini.ex` *(create)* | Gemini harness: `[:terminal, :acp]`, `gemini` TUI + `gemini --acp` (same binary) |
| `backend/lib/legend/harnesses/opencode.ex` *(create)* | OpenCode harness: `[:terminal, :acp]`, `opencode` TUI + `opencode acp` (same binary) |
| `backend/lib/legend/harnesses/openclaw.ex` *(create)* | OpenClaw harness: `[:terminal]` only, `openclaw chat` local TUI |
| `backend/test/legend/harnesses/{codex,gemini,opencode,openclaw}_test.exs` *(create)* | Per-harness unit tests (definition, build_command, acp_command, provision) |
| `backend/config/config.exs` *(modify ~line 64)* | Register the four modules in `:harnesses` |
| `backend/config/runtime.exs` *(modify ~lines 15-18)* | Add `:harness_commands` keys for env override |
| `backend/test/legend/harnesses_test.exs` *(modify ~line 43)* | Cumulative harness-id list assertion |
| `backend/test/legend_web/controllers/harness_controller_test.exs` *(modify ~line 9)* | Cumulative harness-id list assertion |
| `frontend/src/lib/components/sessions/SessionPane.svelte` *(modify ~lines 310-325)* | Generalize the terminal-first hint (harness name; show on local too) |
| `docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md` *(modify)* | Rewrite the Phase 3 section to the as-built design |
| `docs/ARCHITECTURE.md` *(modify)* | Record the new harnesses + the terminal-first dual-transport rationale |

**Reference templates (read, do not modify):** `backend/lib/legend/harnesses/claude_code.ex` (dual-transport + provision template), `backend/lib/legend/harnesses/hermes.ex` (terminal-only template), `backend/test/legend/harnesses/claude_code_test.exs` (test template), `backend/lib/legend/core/harness/terminal.ex` (the `primers/1`, `instructions/1`, opts contract).

**Contract recap (from `terminal.ex`):** `build_command/1` receives opts with optional `:env`, `:messaging` (`%{primer, instructions}`), `:mode` (`:resume` on resume/switch, otherwise fresh), `:session_id`. `Legend.Core.Harness.Terminal.instructions(opts)` returns the initial-prompt text or `nil`. The session_server calls `acp_command(%{env: platform_env})` for ACP and `build_command(build_opts)` for terminal; conversation-id capture (ACP) and the `:switch`/`:resume` routing are handled by the session_server — harnesses only describe how to spawn.

**Resume note (applies to all four):** unlike ClaudeCode, none of these CLIs can *pin* Legend's id as the conversation id at fresh launch (no `--session-id` equivalent), so the harnesses do **not** consume `opts.session_id`. Terminal resume uses each CLI's native "resume last / continue" form, which is best-effort (cwd/last-scoped). ACP resume (`session/load`) still works via the conversation id the spine captures from `session/new`. Cross-transport conversation continuity for these agents is therefore best-effort and not relied upon (documented in Task 6).

---

## Task 1: Codex harness

**Files:**
- Create: `backend/lib/legend/harnesses/codex.ex`
- Create: `backend/test/legend/harnesses/codex_test.exs`
- Modify: `backend/config/config.exs` (~line 64, `:harnesses`)
- Modify: `backend/config/runtime.exs` (~lines 15-18, `:harness_commands`)
- Modify: `backend/test/legend/harnesses_test.exs` (~line 43)
- Modify: `backend/test/legend_web/controllers/harness_controller_test.exs` (~line 9)

**Interfaces:**
- Consumes: `Legend.Core.Harness` (`definition/0`, `provision/1`), `Legend.Core.Harness.Terminal` (`build_command/1`, `instructions/1`), `Legend.Core.Harness.Acp` (`acp_command/1`), `Legend.Core.Harness.Definition`, `Legend.Core.Runtime.CommandSpec`.
- Produces: `Legend.Harnesses.Codex` with `definition().id == "codex"`, `transports: [:terminal, :acp]`, `resumable: true`.

**Background:** Codex terminal CLI is `codex` (npm `@openai/codex`); `codex "PROMPT"` launches the interactive TUI seeded with PROMPT (NOT `codex exec`, which is headless). Resume is `codex resume --last`. ACP is a **separate** adapter `@zed-industries/codex-acp` (binary `codex-acp`), not a `codex` subcommand.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/harnesses/codex_test.exs`:

```elixir
defmodule Legend.Harnesses.CodexTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.Codex

  test "definition: terminal-first, acp second, resumable" do
    d = Codex.definition()
    assert d.id == "codex"
    assert d.name == "Codex"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt positionally as a :pty spec" do
    spec = Codex.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "codex"
    assert List.last(spec.args) == "do the thing"
    refute "resume" in spec.args
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare TUI" do
    assert %{args: []} = Codex.build_command(%{})
  end

  test "build_command resume uses `resume --last` and drops instructions" do
    spec = Codex.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})
    assert spec.args == ["resume", "--last"]
    refute "ignored" in spec.args
  end

  test "caller env is merged over TERM" do
    spec = Codex.build_command(%{env: %{"FOO" => "bar"}})
    assert spec.env == %{"TERM" => "xterm-256color", "FOO" => "bar"}
  end

  test "acp_command returns a :pipes spec for the codex-acp adapter" do
    spec = Codex.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "codex-acp"
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets codex for terminal and codex-acp for acp" do
    term = Codex.provision(:terminal)
    assert term.detect.cmd == "codex"
    assert "--version" in term.detect.args
    assert Enum.join(term.install.args, " ") =~ "@openai/codex"

    acp = Codex.provision(:acp)
    assert acp.detect.cmd == "codex-acp"
    assert acp.detect.io == :pipes
    assert Enum.join(acp.install.args, " ") =~ "@zed-industries/codex-acp"
    assert acp.install.io == :pipes
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && mix test test/legend/harnesses/codex_test.exs`
Expected: FAIL — `Legend.Harnesses.Codex` is undefined (`(CompileError) ... Codex.__struct__/...` or module not available).

- [ ] **Step 3: Create the harness module**

Create `backend/lib/legend/harnesses/codex.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/harnesses/codex_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Register in config and add the override key**

In `backend/config/config.exs`, change the `:harnesses` line (~line 64) from:

```elixir
  harnesses: [Legend.Harnesses.ClaudeCode, Legend.Harnesses.Hermes],
```
to:
```elixir
  harnesses: [
    Legend.Harnesses.ClaudeCode,
    Legend.Harnesses.Codex,
    Legend.Harnesses.Hermes
  ],
```

In `backend/config/runtime.exs`, extend the `:harness_commands` block (~lines 15-18) to add the two Codex keys (keep existing keys):

```elixir
config :legend, :harness_commands,
  claude_code: env!("HARNESS_CLAUDE_CMD", :string, "claude"),
  codex: env!("HARNESS_CODEX_CMD", :string, "codex"),
  codex_acp: env!("HARNESS_CODEX_ACP_CMD", :string, "codex-acp"),
  hermes: env!("HARNESS_HERMES_CMD", :string, "hermes"),
  hermes_primer_flag: env!("HARNESS_HERMES_PRIMER_FLAG", :string, nil)
```

- [ ] **Step 6: Update the two harness-list assertions to the cumulative sorted list**

In `backend/test/legend/harnesses_test.exs` (~line 43) change:
```elixir
    assert ids == ["claude_code", "hermes"]
```
to:
```elixir
    assert ids == ["claude_code", "codex", "hermes"]
```

In `backend/test/legend_web/controllers/harness_controller_test.exs` (~line 9) change:
```elixir
    assert ids == ["claude_code", "hermes"]
```
to:
```elixir
    assert ids == ["claude_code", "codex", "hermes"]
```

- [ ] **Step 7: Run the full backend suite + precommit**

Run: `cd backend && mix precommit`
Expected: compiles warnings-as-errors clean, formatted, all tests pass (the codex tests + updated assertions green).

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/harnesses/codex.ex \
        backend/test/legend/harnesses/codex_test.exs \
        backend/config/config.exs backend/config/runtime.exs \
        backend/test/legend/harnesses_test.exs \
        backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): add Codex (terminal + codex-acp), terminal-first

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Gemini harness

**Files:**
- Create: `backend/lib/legend/harnesses/gemini.ex`
- Create: `backend/test/legend/harnesses/gemini_test.exs`
- Modify: `backend/config/config.exs` (~line 64)
- Modify: `backend/config/runtime.exs` (~lines 15-19)
- Modify: `backend/test/legend/harnesses_test.exs`
- Modify: `backend/test/legend_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Consumes: same contracts as Task 1.
- Produces: `Legend.Harnesses.Gemini`, `id == "gemini"`, `transports: [:terminal, :acp]`, `resumable: true`.

**Background:** Gemini CLI is `gemini` (npm `@google/gemini-cli`); native ACP via `gemini --acp` (same binary). Seed an interactive session with `-i "<prompt>"` (`--prompt-interactive`) — NOT `-p` (headless one-shot). Resume `gemini -r latest`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/harnesses/gemini_test.exs`:

```elixir
defmodule Legend.Harnesses.GeminiTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.Gemini

  test "definition: terminal-first, acp second, resumable" do
    d = Gemini.definition()
    assert d.id == "gemini"
    assert d.name == "Gemini"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt with -i as a :pty spec" do
    spec = Gemini.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "gemini"
    assert spec.args == ["-i", "do the thing"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare REPL" do
    assert %{args: []} = Gemini.build_command(%{})
  end

  test "build_command resume uses `-r latest` and drops instructions" do
    spec = Gemini.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})
    assert spec.args == ["-r", "latest"]
    refute "ignored" in spec.args
  end

  test "acp_command appends --acp to the same binary as a :pipes spec" do
    spec = Gemini.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "gemini"
    assert spec.args == ["--acp"]
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets gemini for both transports" do
    for t <- [:terminal, :acp] do
      p = Gemini.provision(t)
      assert p.detect.cmd == "gemini"
      assert "--version" in p.detect.args
      assert Enum.join(p.install.args, " ") =~ "@google/gemini-cli"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && mix test test/legend/harnesses/gemini_test.exs`
Expected: FAIL — `Legend.Harnesses.Gemini` undefined.

- [ ] **Step 3: Create the harness module**

Create `backend/lib/legend/harnesses/gemini.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/harnesses/gemini_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Register in config and add the override key**

In `backend/config/config.exs`, add `Legend.Harnesses.Gemini` to `:harnesses` (alphabetical-ish, after Codex):

```elixir
  harnesses: [
    Legend.Harnesses.ClaudeCode,
    Legend.Harnesses.Codex,
    Legend.Harnesses.Gemini,
    Legend.Harnesses.Hermes
  ],
```

In `backend/config/runtime.exs`, add the gemini key to `:harness_commands` (after `codex_acp`):

```elixir
  gemini: env!("HARNESS_GEMINI_CMD", :string, "gemini"),
```

- [ ] **Step 6: Update the two harness-list assertions**

In both `backend/test/legend/harnesses_test.exs` and `backend/test/legend_web/controllers/harness_controller_test.exs`, change the list assertion to:
```elixir
    assert ids == ["claude_code", "codex", "gemini", "hermes"]
```

- [ ] **Step 7: Run the full backend suite + precommit**

Run: `cd backend && mix precommit`
Expected: clean compile + format + all tests pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/harnesses/gemini.ex \
        backend/test/legend/harnesses/gemini_test.exs \
        backend/config/config.exs backend/config/runtime.exs \
        backend/test/legend/harnesses_test.exs \
        backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): add Gemini (terminal + native --acp), terminal-first

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: OpenCode harness

**Files:**
- Create: `backend/lib/legend/harnesses/opencode.ex`
- Create: `backend/test/legend/harnesses/opencode_test.exs`
- Modify: `backend/config/config.exs`, `backend/config/runtime.exs`
- Modify: `backend/test/legend/harnesses_test.exs`, `backend/test/legend_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Consumes: same contracts as Task 1.
- Produces: `Legend.Harnesses.OpenCode`, `id == "opencode"`, `transports: [:terminal, :acp]`, `resumable: true`.

**Background:** OpenCode is `opencode` (npm `opencode-ai`); native ACP via `opencode acp` (same binary). Seed the TUI with `--prompt "<text>"` (the positional arg is a project dir, not a prompt). **Known upstream limitation:** `--prompt` only PRE-FILLS the input and does not auto-submit (sst/opencode#3937), so a delegated session shows its task awaiting a manual Enter. Resume `opencode --continue`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/harnesses/opencode_test.exs`:

```elixir
defmodule Legend.Harnesses.OpenCodeTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.OpenCode

  test "definition: terminal-first, acp second, resumable" do
    d = OpenCode.definition()
    assert d.id == "opencode"
    assert d.name == "OpenCode"
    assert d.transports == [:terminal, :acp]
    assert d.resumable
  end

  test "build_command seeds the initial prompt with --prompt as a :pty spec" do
    spec = OpenCode.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.io == :pty
    assert spec.cmd == "opencode"
    assert spec.args == ["--prompt", "do the thing"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command with no instructions launches the bare TUI" do
    assert %{args: []} = OpenCode.build_command(%{})
  end

  test "build_command resume uses --continue and drops instructions" do
    spec = OpenCode.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})
    assert spec.args == ["--continue"]
    refute "ignored" in spec.args
  end

  test "acp_command uses the `acp` subcommand on the same binary as a :pipes spec" do
    spec = OpenCode.acp_command(%{env: %{"FOO" => "bar"}})
    assert spec.io == :pipes
    assert spec.cmd == "opencode"
    assert spec.args == ["acp"]
    assert spec.env["FOO"] == "bar"
  end

  test "provision targets opencode for both transports" do
    for t <- [:terminal, :acp] do
      p = OpenCode.provision(t)
      assert p.detect.cmd == "opencode"
      assert "--version" in p.detect.args
      assert Enum.join(p.install.args, " ") =~ "opencode-ai"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && mix test test/legend/harnesses/opencode_test.exs`
Expected: FAIL — `Legend.Harnesses.OpenCode` undefined.

- [ ] **Step 3: Create the harness module**

Create `backend/lib/legend/harnesses/opencode.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/harnesses/opencode_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Register in config and add the override key**

In `backend/config/config.exs`, add `Legend.Harnesses.OpenCode` to `:harnesses`:

```elixir
  harnesses: [
    Legend.Harnesses.ClaudeCode,
    Legend.Harnesses.Codex,
    Legend.Harnesses.Gemini,
    Legend.Harnesses.Hermes,
    Legend.Harnesses.OpenCode
  ],
```

In `backend/config/runtime.exs`, add the opencode key to `:harness_commands`:

```elixir
  opencode: env!("HARNESS_OPENCODE_CMD", :string, "opencode"),
```

- [ ] **Step 6: Update the two harness-list assertions**

In both test files change the list assertion to:
```elixir
    assert ids == ["claude_code", "codex", "gemini", "hermes", "opencode"]
```

- [ ] **Step 7: Run the full backend suite + precommit**

Run: `cd backend && mix precommit`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/harnesses/opencode.ex \
        backend/test/legend/harnesses/opencode_test.exs \
        backend/config/config.exs backend/config/runtime.exs \
        backend/test/legend/harnesses_test.exs \
        backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): add OpenCode (terminal + native acp), terminal-first

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: OpenClaw harness (terminal-only)

**Files:**
- Create: `backend/lib/legend/harnesses/openclaw.ex`
- Create: `backend/test/legend/harnesses/openclaw_test.exs`
- Modify: `backend/config/config.exs`, `backend/config/runtime.exs`
- Modify: `backend/test/legend/harnesses_test.exs`, `backend/test/legend_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Harness`, `Legend.Core.Harness.Terminal` (NOT `Acp` — terminal-only), `Definition`, `CommandSpec`.
- Produces: `Legend.Harnesses.OpenClaw`, `id == "openclaw"`, `transports: [:terminal]`, `resumable: true`.

**Background:** OpenClaw's interactive standalone TUI is `openclaw chat` (alias for `openclaw tui --local` — the embedded runtime, NOT `openclaw acp`, which is a Gateway bridge). A stable session key is pinned via `--session main`; the initial prompt is seeded with `--message`. Requires a one-time `openclaw setup`/`onboard` + model auth in the agent's own config before first use (documented). ACP is intentionally not offered.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/harnesses/openclaw_test.exs`:

```elixir
defmodule Legend.Harnesses.OpenClawTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.OpenClaw

  test "definition: terminal-only, resumable" do
    d = OpenClaw.definition()
    assert d.id == "openclaw"
    assert d.name == "OpenClaw"
    assert d.transports == [:terminal]
    assert d.resumable
  end

  test "build_command runs the local chat TUI with a pinned session as a :pty spec" do
    spec = OpenClaw.build_command(%{})
    assert spec.io == :pty
    assert spec.cmd == "openclaw"
    assert spec.args == ["chat", "--session", "main"]
    assert spec.env["TERM"] == "xterm-256color"
  end

  test "build_command seeds the initial prompt with --message" do
    spec = OpenClaw.build_command(%{messaging: %{primer: "", instructions: "do the thing"}})
    assert spec.args == ["chat", "--session", "main", "--message", "do the thing"]
  end

  test "build_command resume reuses the pinned session without a message" do
    spec = OpenClaw.build_command(%{mode: :resume, messaging: %{primer: "", instructions: "ignored"}})
    assert spec.args == ["chat", "--session", "main"]
    refute "ignored" in spec.args
    refute "--message" in spec.args
  end

  test "does not implement the Acp behaviour" do
    refute function_exported?(OpenClaw, :acp_command, 1)
  end

  test "provision targets openclaw for terminal" do
    p = OpenClaw.provision(:terminal)
    assert p.detect.cmd == "openclaw"
    assert "--version" in p.detect.args
    assert Enum.join(p.install.args, " ") =~ "openclaw"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && mix test test/legend/harnesses/openclaw_test.exs`
Expected: FAIL — `Legend.Harnesses.OpenClaw` undefined.

- [ ] **Step 3: Create the harness module**

Create `backend/lib/legend/harnesses/openclaw.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/harnesses/openclaw_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Register in config and add the override key**

In `backend/config/config.exs`, add `Legend.Harnesses.OpenClaw` to `:harnesses` (final list):

```elixir
  harnesses: [
    Legend.Harnesses.ClaudeCode,
    Legend.Harnesses.Codex,
    Legend.Harnesses.Gemini,
    Legend.Harnesses.Hermes,
    Legend.Harnesses.OpenCode,
    Legend.Harnesses.OpenClaw
  ],
```

In `backend/config/runtime.exs`, add the openclaw key to `:harness_commands`:

```elixir
  openclaw: env!("HARNESS_OPENCLAW_CMD", :string, "openclaw"),
```

- [ ] **Step 6: Update the two harness-list assertions to the final list**

In both test files change the list assertion to:
```elixir
    assert ids == ["claude_code", "codex", "gemini", "hermes", "opencode", "openclaw"]
```

- [ ] **Step 7: Run the full backend suite + precommit**

Run: `cd backend && mix precommit`
Expected: clean — all harness tests + both updated assertions green.

- [ ] **Step 8: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/harnesses/openclaw.ex \
        backend/test/legend/harnesses/openclaw_test.exs \
        backend/config/config.exs backend/config/runtime.exs \
        backend/test/legend/harnesses_test.exs \
        backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): add OpenClaw (terminal-only local TUI)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Generalize the terminal-first hint

**Files:**
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte` (~lines 310-325)

**Interfaces:**
- Consumes: the existing `session` (`.transport`, `.runtime_id`) and `harness` (`.transports`, `.name`) reactive state already in scope in `SessionPane.svelte`, and the existing `switchTransport('acp')` function.
- Produces: no new exports.

**Background:** The Phase 2 hint is hardcoded to "Claude Code" and gated to cloud (`runtime_id !== 'local_pty'`). The new agents default to `:terminal` even on local, so the hint should (a) name the actual harness and (b) appear on local too. The condition becomes: in terminal transport on any ACP-capable harness. (Local Claude Code defaults to ACP, so it won't show the hint unless the user manually switched to terminal — acceptable.)

- [ ] **Step 1: Read the current hint block**

Read `frontend/src/lib/components/sessions/SessionPane.svelte` around lines 305-330 to confirm the exact current markup and the in-scope variable names (`session`, `harness`, `switchTransport`).

- [ ] **Step 2: Replace the gate and copy**

Change the gate from:
```svelte
{#if session.transport === 'terminal' && harness?.transports?.includes('acp') && session.runtime_id !== 'local_pty'}
```
to (drop the runtime gate):
```svelte
{#if session.transport === 'terminal' && harness?.transports?.includes('acp')}
```

And change the paragraph copy from the hardcoded "Sign in to Claude Code in the terminal, then …" to use the harness name. The full paragraph becomes:
```svelte
    <p class="text-micro text-ink-3">
      Sign in to {harness?.name ?? 'the agent'} in the terminal, then
      <button
        type="button"
        class="pointer-events-auto text-micro text-ink-3 underline underline-offset-2 hover:text-ink-2"
        onclick={() => switchTransport('acp')}
      >switch to rich</button>
      for the structured view.
    </p>
```
Remove the now-stale `<!-- TODO: switch to a capabilities-based cloud gate when more runtimes exist -->` comment (the gate is no longer runtime-specific). Keep the surrounding `<div class="pointer-events-none absolute inset-x-0 bottom-0 …">` wrapper unchanged.

- [ ] **Step 3: Verify the frontend typechecks**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings (same as before the change).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/sessions/SessionPane.svelte
git commit -m "feat(fe): terminal-first hint names the harness and shows on local

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Docs — spec Phase 3 section + ARCHITECTURE

**Files:**
- Modify: `docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md`
- Modify: `docs/ARCHITECTURE.md`

**Interfaces:** none (documentation).

**Background:** The Phase 3 design changed materially from the original spec section: auth is terminal-first (each CLI's own login) rather than API-key entry; OpenCode was added; OpenClaw is terminal-only (its ACP is a Gateway bridge); the three ACP agents are dual-transport `[:terminal, :acp]`; there is no credential UI; and terminal-mode primers/MCP + cross-transport conversation continuity are explicitly scoped out for the new agents. Keep this accurate so future work builds on reality.

- [ ] **Step 1: Rewrite the spec's "Codex + Gemini (Phase 3 — thin)" section**

In `docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md`, retitle the Phase 3 section to **"Codex + Gemini + OpenCode + OpenClaw (Phase 3 — built)"** and replace its body to record the as-built design. It must state, verbatim in substance:
- Each new agent is a thin harness module (`Legend.Harnesses.{Codex,Gemini,OpenCode,OpenClaw}`); the protocol engine, timeline, UI, channel, provisioning, transport switching, and conversation-id capture are shared and unchanged.
- **Auth is terminal-first:** dual-transport agents are `transports: [:terminal, :acp]` (terminal default — authenticate via the agent's own CLI login in the PTY, then switch to rich). Legend stores **no** credential; there is no API-key entry surface.
- **Codex:** terminal `codex` (npm `@openai/codex`), initial prompt positional, resume `codex resume --last`; ACP via the separate `@zed-industries/codex-acp` adapter (`codex-acp` binary); `provision/1` per-transport (codex vs codex-acp).
- **Gemini:** terminal `gemini` (npm `@google/gemini-cli`), initial prompt `-i`, resume `-r latest`; native ACP `gemini --acp` (same binary); single `provision/1`. Note the upstream non-TTY-auth/hang risks to validate at live bring-up.
- **OpenCode:** terminal `opencode` (npm `opencode-ai`), initial prompt `--prompt` (pre-fill only, no auto-submit — sst/opencode#3937), resume `--continue`; native ACP `opencode acp` (same binary); single `provision/1`.
- **OpenClaw:** terminal-only (`transports: [:terminal]`), `openclaw chat` local TUI with pinned `--session main` + `--message`; requires one-time `openclaw setup`/auth. ACP not offered because `openclaw acp` is a Gateway bridge needing a separate Gateway service.
- **Scoped out for the new agents (intentional):** terminal-mode library/messaging primers and signal-bus MCP registration (config-file based on these CLIs, not per-launch flags) — these work over ACP only; and conversation-id pinning at terminal fresh launch (no CLI supports it like ClaudeCode's `--session-id`), so terminal resume is best-effort (last/cwd-scoped) and cross-transport conversation continuity is not relied upon.

Also update the spec header `**Status:**` line to note Phase 3 built, and the "Codex / Gemini / Gemini harnesses" mentions in **Non-goals (Phase 1)** / **Phasing** if they now read as not-yet-built (mark Phase 3 built).

- [ ] **Step 2: Update ARCHITECTURE.md**

In `docs/ARCHITECTURE.md`, update the harness/ACP entries to record: the six registered harnesses (ClaudeCode, Codex, Gemini, Hermes, OpenCode, OpenClaw); that ACP Phase 3 is built; and the **terminal-first dual-transport rationale** — new ACP agents order `transports: [:terminal, :acp]` so first-run auth happens in the PTY via the agent's own login (no stored credential), with the rich ACP UI one toggle away; OpenClaw is terminal-only because its ACP is a Gateway bridge. Note the accepted caveat that terminal-mode primers/MCP for the new agents are deferred (ACP carries them). Match the file's existing tone/structure (find the existing harness/ACP section rather than appending a new top-level one).

- [ ] **Step 3: Sanity-check the docs**

Run: `cd /Users/daniel/Development/legend && grep -n "Phase 3" docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md docs/ARCHITECTURE.md`
Expected: the Phase 3 references read as built and name all four agents. Re-read both edited sections once for accuracy against the harness modules created in Tasks 1-4.

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/legend
git add docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md docs/ARCHITECTURE.md
git commit -m "docs(acp): phase 3 built — Codex/Gemini/OpenCode terminal+ACP, OpenClaw terminal-only

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (performed during planning)

**Spec coverage:** Codex ✓ (T1), Gemini ✓ (T2), OpenCode ✓ (T3, user-added), OpenClaw ✓ (T4, user-added, terminal-only per user direction), terminal-first auth ✓ (transport ordering + no credential UI), rich ACP for the three ✓ (shared spine, `acp_command` per harness), provisioning ✓ (per task), frontend ✓ (T5), docs ✓ (T6).

**Placeholder scan:** every step contains the actual module/test code and verbatim commands; no TBD/TODO-implement.

**Type/name consistency:** module names `Legend.Harnesses.{Codex,Gemini,OpenCode,OpenClaw}`, ids `codex/gemini/opencode/openclaw`, config keys `:codex/:codex_acp/:gemini/:opencode/:openclaw` are consistent across module, config, tests, and the cumulative list assertions (`["claude_code","codex","gemini","hermes","opencode","openclaw"]`). All harnesses follow the ClaudeCode/Hermes `configured_command/2` + `instruction_args/1` shape; the small duplication across harnesses matches the established per-harness self-contained convention (ClaudeCode and Hermes already duplicate `configured_command/2`), chosen over a shared helper to keep each task an independent review unit.

**Known limitations recorded (not defects):** OpenCode `--prompt` no auto-submit (#3937); terminal resume best-effort (no pin-at-create id) for all four; terminal-mode primers/MCP deferred to ACP; Gemini non-TTY ACP auth/hang risks flagged for live bring-up. These are documented in moduledocs + the spec, not silently dropped.
