# ACP Rich Sessions — Phase 2 (Cloud / Sprites) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Execute tasks in the order written** — Task 3 (default transport) deliberately precedes Task 4 (provisioning) so the existing provisioning tests keep matching the terminal detect spec.

**Goal:** Run an ACP (rich-UI) Claude Code session on a sprites.dev cloud sandbox — the adapter speaks JSON-RPC over a non-PTY (`:pipes`) WSS exec, reaches the Legend MCP signal bus + library over the existing reverse tunnel, and resumes via `session/load`.

**Architecture:** The orchestration is already transport- and location-agnostic from Phase 1 (the `SessionServer` opens the tunnel for any runtime that declares one, and `acp_mcp_servers/3` already emits the cloud HTTP MCP entry at `base_url <> "/api/mcp"`). Phase 2 fills the one real gap: `Legend.Sprites.Exec` gains a `:pipes` mode (Docker-style 1-byte stream-id demux over the WSS exec, `tty=false`), the ACP adapter (`claude-code-acp`) is provisioned into the sprite, and cloud Claude Code defaults to the `:terminal` transport so the human authenticates once in the PTY before switching to the rich (`:acp`) view on the same persisted sprite/conversation.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 / AshSqlite; `Mint.WebSocket` (sprites WSS); SvelteKit 2 / Svelte 5 runes / Tailwind v4 (frontend); sprites.dev cloud sandbox.

## Verified facts (live against api.sprites.dev, 2026-06-22)

These are the protocol/environment constants this plan depends on, captured by a live throwaway-sprite probe (the prior `Sprites.Exec` moduledoc documented only `tty=true`).

**Non-TTY (`tty=false`) exec wire format — Docker-style 1-byte stream-id demux:**
- Spawn query identical to the TTY path except `tty=false` (omitting `tty` also yields `tty=false`); `stdin=true&detachable=true` unchanged. `rows`/`cols` are irrelevant under `tty=false`.
- Leading TEXT frames unchanged: optional `{"type":"debug",...}` lines, then `{"type":"session_info","session_id":"<id>",...,"tty":false}`.
- **Output BINARY frames carry a 1-byte stream-id prefix:** `0x01`+payload → **stdout**, `0x02`+payload → **stderr**, `0x03`+byte → exit-status control (redundant with the TEXT exit frame — ignore it).
- **stdin BINARY frames must be prefixed with `0x00`** (`<<0>> <> data`). Raw (unprefixed) stdin bytes are silently dropped.
- Exit is ALSO signalled by the existing TEXT frame `{"type":"exit","exit_code":N}` (already handled), then WS CLOSE 1000.
- **TTY mode unchanged:** BINARY frames are raw terminal bytes with no prefix; stdin is raw bytes; this plan must not alter that path.

**Default sprite image (Ubuntu 25.10) toolchain — already present:** `node` v22.20.0, `npm` 11.16.0, `npx`, `claude` 2.1.168. **`claude-code-acp` is MISSING** → install `npm i -g @zed-industries/claude-code-acp` (detect `claude-code-acp --version`). Because `claude` is already installed, the terminal `provision` detect passes with no install on a fresh sprite.

## Global Constraints

- **Clean over compatibility.** Replace signatures outright and migrate ALL callers rather than adding shims (`provision/0`→`provision/1`, `default_transport/1`→`default_transport/2`). When you change a function's arity, grep BOTH definers and callers: `grep -rn "<name>" lib/ test/`. [[clean-over-compat-early-stage]]
- **TTY path is sacred.** The existing `tty=true` exec behavior (terminal sessions, local + cloud) must be byte-for-byte unchanged. All `:pipes` behavior is gated on `spec.io == :pipes` / the session_info `"tty"` field.
- **ACP never reattaches; it relaunches + `session/load`.** Per the design, cloud ACP resume is a fresh adapter process replayed via `session/load`, never a PTY-style reattach-to-live. A transport switch always starts a fresh process for the new transport.
- **No new PTY-injection vector.** ACP stdin is JSON-RPC frames from `Acp.Connection` via `runtime.write/2`; the only transformation `Sprites.Exec` applies is the `<<0>>` stdin prefix. Agent-controllable strings reaching a PTY remain sanitized at `Terminal.nudge_line/3`.
- **Registry ids stay strings.** Never `String.to_atom/1` on a harness/runtime/tunnel/transport id from user input.
- **Auth model = terminal-first, then switch (no stored model credential).** Cloud Claude Code defaults to `:terminal`; the human authenticates once in the PTY; credentials persist in the sprite's `~/.claude`; the user flips to `rich` (ACP `session/load`). Legend stores no model credential.
- **Provisioning runs on every launch/relaunch** (including the `set_transport` switch), so the ACP adapter installs lazily when a cloud session first switches to rich.
- **Frontend token discipline:** Legend tokens (`text-ink-*`, `bg-shell/app/panel`, `text-micro…title`) + shell primitives; never raw shadcn neutral classes / ad-hoc hex / ad-hoc `text-[Npx]`.
- **Verification gates:** backend `cd backend && mix precommit` (compile --warnings-as-errors + format + test) green; frontend `cd frontend && bun run check` 0 errors / 0 warnings. Live cloud tests are `@tag :live_sprites`, excluded by default.

---

## Task 1: `Sprites.Exec` — `:pipes` wire-format pure helpers

Extract the wire-format decisions into pure, offline-testable functions before touching the GenServer.

**Files:**
- Modify: `backend/lib/legend/sprites/exec.ex`
- Test: `backend/test/legend/sprites/exec_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Runtime.CommandSpec` (`%CommandSpec{io: :pty | :pipes}`).
- Produces (new public/`@doc false` pure functions on `Legend.Sprites.Exec`):
  - `spawn_query/2` — io-aware: `io: :pipes` → `tty=false`; `:pty`/default → `tty=true` (unchanged).
  - `demux_output/2 :: (binary(), pipes? :: boolean()) -> {:stdout, binary()} | {:stderr, binary()} | {:exit, non_neg_integer()} | :ignore`.
  - `encode_stdin/2 :: (binary(), pipes? :: boolean()) -> binary()` (`pipes?` prefixes `<<0>>`).

- [ ] **Step 1: Write failing tests for the io-aware spawn query + an `io: :pipes` sh spec (SpriteProxy bridge shape)**

Add to `backend/test/legend/sprites/exec_test.exs`:

```elixir
test "spawn_query/2 uses tty=false for a :pipes spec" do
  qs = Exec.spawn_query(%CommandSpec{cmd: "claude-code-acp", io: :pipes}, [])
  assert qs =~ "tty=false"
  refute qs =~ "tty=true"
  assert qs =~ "stdin=true"
  assert qs =~ "detachable=true"
  assert qs =~ "cmd=claude-code-acp"
end

test "spawn_query/2 keeps tty=true for a :pty spec (unchanged)" do
  qs = Exec.spawn_query(%CommandSpec{cmd: "bash", args: ["-lc", "echo hi"], io: :pty}, rows: 30, cols: 100)
  assert qs =~ "tty=true"
  assert qs =~ "rows=30"
  assert qs =~ "cols=100"
end

# SpriteProxy bridge commands (sprite_proxy.ex sh/1) are io: :pipes — confirm they
# take the tty=false branch (this is the only offline guard for that regression).
test "spawn_query/2 yields tty=false for an io: :pipes sh bridge spec" do
  qs = Exec.spawn_query(%CommandSpec{cmd: "sh", args: ["-c", "pgrep -f x"], io: :pipes}, [])
  assert qs =~ "tty=false"
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: FAIL (`spawn_query` hardcodes `tty=true`).

- [ ] **Step 3: Make `spawn_query/2` io-aware**

In `backend/lib/legend/sprites/exec.ex`, add `io` to the match and compute the flag:

```elixir
def spawn_query(%CommandSpec{cmd: bin, args: args, io: io}, opts) do
  rows = Keyword.get(opts, :rows, 24)
  cols = Keyword.get(opts, :cols, 80)
  tty = if io == :pipes, do: "false", else: "true"

  fixed = [
    {"path", bin},
    {"tty", tty},
    {"stdin", "true"},
    {"detachable", "true"},
    {"rows", Integer.to_string(rows)},
    {"cols", Integer.to_string(cols)}
  ]

  cmd_pairs = Enum.map([bin | args], &{"cmd", &1})

  (fixed ++ cmd_pairs)
  |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(v)}" end)
end
```

- [ ] **Step 4: Run the spawn-query tests**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS (incl. the pre-existing `tty=true` default test).

- [ ] **Step 5: Write failing tests for `demux_output/2` and `encode_stdin/2`**

```elixir
describe "demux_output/2 (pipes mode)" do
  test "0x01 prefix is stdout" do
    assert Exec.demux_output(<<1>> <> "hello", true) == {:stdout, "hello"}
  end

  test "0x02 prefix is stderr" do
    assert Exec.demux_output(<<2>> <> "oops", true) == {:stderr, "oops"}
  end

  test "0x03 prefix is the exit control frame (code as a byte)" do
    assert Exec.demux_output(<<3, 7>>, true) == {:exit, 7}
  end

  test "an empty or unknown-stream frame is ignored" do
    assert Exec.demux_output(<<>>, true) == :ignore
    assert Exec.demux_output(<<9>> <> "x", true) == :ignore
  end
end

test "demux_output/2 returns raw stdout in tty mode (no prefix)" do
  assert Exec.demux_output("raw terminal bytes", false) == {:stdout, "raw terminal bytes"}
end

test "encode_stdin/2 prefixes 0x00 in pipes mode, passes through in tty mode" do
  assert Exec.encode_stdin("line\n", true) == <<0>> <> "line\n"
  assert Exec.encode_stdin("line\n", false) == "line\n"
end
```

- [ ] **Step 6: Run to verify failure**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: FAIL ("function demux_output/2 undefined").

- [ ] **Step 7: Implement the pure helpers** (place near the other public helpers, above the GenServer API)

```elixir
@doc """
Splits a non-TTY exec BINARY output frame by its 1-byte stream-id prefix:
`0x01` stdout, `0x02` stderr, `0x03` exit-status control (code as a byte). In
TTY mode (`pipes? == false`) frames are raw stdout bytes with no prefix.
"""
@spec demux_output(binary(), boolean()) ::
        {:stdout, binary()} | {:stderr, binary()} | {:exit, non_neg_integer()} | :ignore
def demux_output(data, false), do: {:stdout, data}
def demux_output(<<1, rest::binary>>, true), do: {:stdout, rest}
def demux_output(<<2, rest::binary>>, true), do: {:stderr, rest}
def demux_output(<<3, code, _::binary>>, true), do: {:exit, code}
def demux_output(_other, true), do: :ignore

@doc "Encodes a stdin write: non-TTY exec requires a 0x00 stream-id prefix."
@spec encode_stdin(binary(), boolean()) :: binary()
def encode_stdin(data, true), do: <<0>> <> data
def encode_stdin(data, false), do: data
```

- [ ] **Step 8: Run all Task-1 tests**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/sprites/exec.ex backend/test/legend/sprites/exec_test.exs
git commit -m "feat(sprites): io-aware spawn query + pipes demux/stdin helpers"
```

---

## Task 2: `Sprites.Exec` — wire the GenServer into `:pipes` mode

Make the live exec use the Task-1 helpers: track pipes/tty, demux output to the right owner message, prefix stdin, and merge stderr into the `run/3` result so provisioning error reporting still works.

**Files:**
- Modify: `backend/lib/legend/sprites/exec.ex`
- Test: `backend/test/legend/sprites/exec_test.exs`

**Interfaces:**
- Consumes: `demux_output/2`, `encode_stdin/2` (Task 1).
- Produces: the `Legend.Core.Runtime` owner contract unchanged — stdout → `{:runtime_output, bin}`, stderr → `{:runtime_stderr, bin}` (matching `LocalPty :pipes`), exit → `{:runtime_exit, code}`. `start/3`, `attach/3`, `run/3`, `write/2` signatures unchanged.

- [ ] **Step 1: Add `pipes?` to state, seeded from the spec / session_info**

In `init/1`, seed `pipes?` from the spec's `io` for `:spawn`/`:run`; for `:attach` seed `false` and rely on the session_info `"tty"` field. Add `pipes?: false` to the state map and set it:

```elixir
def init({mode, name, arg, opts}) do
  owner = Map.fetch!(opts, :owner)

  pipes? =
    case mode do
      :attach -> false
      _ -> match?(%CommandSpec{io: :pipes}, arg)
    end

  state = %{name: name, owner: owner, conn: nil, websocket: nil, ref: nil,
            exec_id: nil, exited?: false, pipes?: pipes?}
  ...
```

> Note: ACP execs never attach (guaranteed by Task 5's terminal-only attach gate + relaunch-on-switch), so the `:attach` path is only ever a TTY terminal reattach (`pipes? == false`). The session_info `"tty"` capture in Step 2 keeps this correct even if that ever changes.

- [ ] **Step 2: Capture authoritative `tty` from `session_info`**

In `dispatch_frame/2`'s `session_info` clause, set `pipes?` from the frame's `"tty"` field:

```elixir
{:ok, %{"type" => "session_info", "session_id" => id} = info} ->
  %{state | exec_id: state.exec_id || to_string(id), pipes?: info["tty"] == false}
```

- [ ] **Step 3: Demux output frames through the owner contract**

Replace the `dispatch_frame({:binary, data}, state)` clause:

```elixir
defp dispatch_frame({:binary, data}, state) do
  case demux_output(data, state.pipes?) do
    {:stdout, payload} -> send(state.owner, {:runtime_output, payload})
    {:stderr, payload} -> send(state.owner, {:runtime_stderr, payload})
    # The TEXT {"type":"exit"} frame drives termination; the 0x03 control frame
    # is redundant — ignore it so we don't double-send {:runtime_exit}.
    {:exit, _code} -> :noop
    :ignore -> :noop
  end

  state
end
```

(`demux_output(data, false)` returns `{:stdout, data}` → TTY behavior byte-for-byte unchanged.)

- [ ] **Step 4: Prefix stdin writes**

```elixir
def handle_cast({:write, data}, state) do
  {:noreply, send_frame(state, {:binary, encode_stdin(data, state.pipes?)})}
end
```

- [ ] **Step 5: Write a failing offline test for the `run/3` collector merging stderr**

Promote `collect_run/3` to a public `@doc false` function so the test can call it. Add:

```elixir
test "collect_run accumulates stdout and stderr into the combined result" do
  parent = self()
  ref = make_ref()
  collector = spawn(fn -> Legend.Sprites.Exec.collect_run(parent, ref, "") end)
  send(collector, {:runtime_output, "OUT"})
  send(collector, {:runtime_stderr, "ERR"})
  send(collector, {:runtime_exit, 3})
  assert_receive {^ref, 3, combined}
  assert combined =~ "OUT"
  assert combined =~ "ERR"
end
```

- [ ] **Step 6: Run to verify failure**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: FAIL (collector ignores `{:runtime_stderr, _}`; or `collect_run/3` is private).

- [ ] **Step 7: Update `collect_run/3` to accumulate both streams**

```elixir
@doc false
def collect_run(parent, ref, acc) do
  receive do
    {:runtime_output, data} -> collect_run(parent, ref, acc <> data)
    {:runtime_stderr, data} -> collect_run(parent, ref, acc <> data)
    {:runtime_exit, code} -> send(parent, {ref, code, acc})
  end
end
```

- [ ] **Step 8: Run the offline tests**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS.

- [ ] **Step 9: Add a gated live test for the pipes exec round-trip (auth-free)**

Exercises the real wire format end-to-end with no model auth (runs `sh`). Guard on the value `Exec` actually reads (`Application.get_env(:legend, :sprites_token)`), not the bare env var:

```elixir
@tag :live_sprites
test "live: non-TTY exec demuxes stdout/stderr and reports the exit code" do
  if Application.get_env(:legend, :sprites_token) in [nil, ""],
    do: flunk("set SPRITES_TOKEN (app env :sprites_token) for :live_sprites")

  name = "lt-pipes-#{System.system_time(:second)}"
  {:ok, _} = Legend.Sprites.Client.create_sprite(name)
  Process.sleep(3_000)

  spec = %CommandSpec{cmd: "sh", args: ["-c", "printf OUT; printf ERR 1>&2; exit 5"], io: :pipes}
  result = Legend.Sprites.Exec.run(name, spec, 60_000)
  Legend.Sprites.Client.delete_sprite(name)

  assert {:ok, %{stdout: combined, status: 5}} = result
  assert combined =~ "OUT"
  assert combined =~ "ERR"
end
```

Then ensure `:live_sprites` is excluded by default: read `backend/test/test_helper.exs`; it currently has no `exclude`, so add `ExUnit.configure(exclude: [:live_sprites])` (preserving any existing config). Note the tag in the commit message.

- [ ] **Step 10: Run offline (live excluded) + the live test explicitly**

Run (offline): `cd backend && mix test test/legend/sprites/exec_test.exs` → PASS, live test excluded.
Run (live, this machine has the token): `cd backend && mix test test/legend/sprites/exec_test.exs --only live_sprites` → PASS (throwaway sprite asserts OUT/ERR/status 5, deleted).

- [ ] **Step 11: Commit**

```bash
git add backend/lib/legend/sprites/exec.ex backend/test/legend/sprites/exec_test.exs backend/test/test_helper.exs
git commit -m "feat(sprites): :pipes exec mode (stream-id demux, stdin prefix, stderr-merged run)"
```

---

## Task 3: Runtime-aware default transport (cloud Claude Code opens in terminal)

So the human can authenticate, a provisioning (cloud) runtime defaults a fresh ACP-capable session to `:terminal`; local stays on the harness default (`:acp` for Claude Code). **This precedes Task 4 so the existing provisioning tests' no-transport sessions default to `:terminal` and keep matching the terminal detect spec.**

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (`default_transport`, `:start` change)
- Test: `backend/test/legend/core/agents/session_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Runtime.capabilities/1` (`%{provisions?: boolean()}`), harness `transports`.
- Produces: `default_transport(harness_id, runtime_id) :: :terminal | :acp` (replaces `default_transport/1`).

- [ ] **Step 1: Write the failing test — drive the cloud case through the REGISTERED `"test"` runtime**

`sprites` is not registered in `config/test.exs`, so assert against `"test"` with `provisions?: true` set (the existing provisioning-test pattern). Add to `session_test.exs`:

```elixir
alias Legend.Runtimes.Test, as: TestRuntime

test "default_transport prefers terminal on a provisioning runtime, acp on a local one" do
  alias Legend.Core.Agents.Session
  on_exit(fn -> Application.delete_env(:legend, :test_runtime_capabilities) end)

  # Local, non-provisioning runtime: harness default (claude_code → :acp).
  TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
  assert Session.default_transport("claude_code", "test") == :acp
  assert Session.default_transport("claude_code", "local_pty") == :acp

  # Provisioning (cloud-style) runtime: terminal-first for an ACP-capable harness.
  TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})
  assert Session.default_transport("claude_code", "test") == :terminal
  # A terminal-only harness is :terminal regardless.
  assert Session.default_transport("hermes", "test") == :terminal
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: FAIL (`default_transport/2` undefined).

- [ ] **Step 3: Implement `default_transport/2`**

```elixir
@doc false
def default_transport(harness_id, runtime_id) do
  with {:ok, hmod} <- Legend.Core.Harness.Registry.fetch(harness_id),
       transports = hmod.definition().transports,
       [first | _] <- transports do
    if remote_auth_runtime?(runtime_id) and :terminal in transports do
      :terminal
    else
      first
    end
  else
    _ -> :terminal
  end
end

# A provisioning runtime is a fresh remote box needing interactive (PTY) first-run
# auth, so an ACP-capable session starts in :terminal until the human authenticates;
# they then switch to :acp on the same persisted sprite.
defp remote_auth_runtime?(runtime_id) do
  case Legend.Core.Runtime.Registry.fetch(runtime_id) do
    {:ok, rmod} -> Legend.Core.Runtime.capabilities(rmod).provisions?
    :error -> false
  end
end
```

- [ ] **Step 4: Update the `:start` change to pass `runtime_id`**

In the `create :start` action's transport-default change:

```elixir
hid = Ash.Changeset.get_attribute(changeset, :harness_id)
rid = Ash.Changeset.get_attribute(changeset, :runtime_id)
Ash.Changeset.force_change_attribute(changeset, :transport, default_transport(hid, rid))
```

- [ ] **Step 5: Run the test**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the agents suite — confirm the provisioning-test transport flip is benign**

Run: `cd backend && mix test test/legend/core/agents/`
Expected: PASS. Note: `session_provisioning_test.exs` sets `provisions?: true` and creates claude_code/test sessions with no transport — they now default to `:terminal` (was `:acp`). Provision is still transport-blind (`/0`, claude detect) at this point, so detect/install assertions hold. **If any provisioning/ACP test asserts a transport-specific launch (e.g. `{:test_runtime, :write, init}` for the ACP handshake) and now fails, pin its intended `transport:` explicitly in that test** rather than weakening the default.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_test.exs
git commit -m "feat(sessions): runtime-aware default transport (cloud opens terminal-first)"
```

---

## Task 4: Transport-aware provisioning (install `claude-code-acp` for cloud ACP)

A cloud session switching to `:acp` needs the adapter in the sprite. Make `provision` transport-aware; migrate ALL `provision_for` callers.

**Files:**
- Modify: `backend/lib/legend/core/harness.ex` (callback, `provision_for/2`, new `provisionable?/1`)
- Modify: `backend/lib/legend/harnesses/claude_code.ex`
- Modify: `backend/lib/legend_web/controllers/harness_controller.ex` (caller migration)
- Modify: `backend/lib/legend/core/agents/session_server.ex` (`maybe_provision` passes transport)
- Modify: `backend/test/support/runtimes/test.ex` (detect clause generalization)
- Test: `backend/test/legend/core/harness_provision_test.exs`, `backend/test/legend/harnesses/claude_code_test.exs` (create), `backend/test/legend/core/agents/session_provisioning_test.exs`, `backend/test/legend_web/controllers/harness_controller_test.exs` (re-verify)

**Interfaces:**
- Consumes: `session.transport`.
- Produces:
  - `@callback provision(transport :: :terminal | :acp) :: %{detect, install} | nil` (replaces `provision/0`).
  - `Legend.Core.Harness.provision_for(module, transport) :: %{detect, install} | nil`.
  - `Legend.Core.Harness.provisionable?(module) :: boolean()` (transport-independent: does the harness implement `provision/1` at all).
  - `ClaudeCode.provision(:terminal)` → `claude`; `ClaudeCode.provision(:acp)` → `claude-code-acp`.

- [ ] **Step 1: Migrate the migration grep first**

Run: `cd backend && grep -rn "provision_for\|def provision\|provisionable" lib/ test/`
Confirm the callers to migrate: `session_server.ex:312`, `harness_controller.ex:16`, `harness_provision_test.exs` (3 lines). Only `ClaudeCode` defines `provision`.

- [ ] **Step 2: Write the failing harness unit test**

Create `backend/test/legend/harnesses/claude_code_test.exs`:

```elixir
defmodule Legend.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.ClaudeCode

  test "provision/1 targets claude for terminal, claude-code-acp for acp" do
    assert ClaudeCode.provision(:terminal).detect.cmd == "claude"

    acp = ClaudeCode.provision(:acp)
    assert acp.detect.cmd == "claude-code-acp"
    assert acp.detect.io == :pipes
    assert Enum.join(acp.install.args, " ") =~ "@zed-industries/claude-code-acp"
    assert acp.install.io == :pipes
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs`
Expected: FAIL (`provision/1` undefined).

- [ ] **Step 4: Update the behaviour + add `provisionable?/1`**

In `backend/lib/legend/core/harness.ex`:

```elixir
@callback provision(transport :: Definition.transport()) ::
            %{detect: Legend.Core.Runtime.CommandSpec.t(), install: Legend.Core.Runtime.CommandSpec.t()} | nil
@optional_callbacks setup: 0, apply_setup: 0, provision: 1

@doc "The harness's provision spec for a transport, or nil if it has no installer."
@spec provision_for(module(), Definition.transport()) ::
        %{detect: Legend.Core.Runtime.CommandSpec.t(), install: Legend.Core.Runtime.CommandSpec.t()} | nil
def provision_for(module, transport) do
  if Code.ensure_loaded?(module) and function_exported?(module, :provision, 1) do
    module.provision(transport)
  else
    nil
  end
end

@doc "Whether a harness can install itself on a provisioning runtime (transport-independent)."
@spec provisionable?(module()) :: boolean()
def provisionable?(module) do
  Code.ensure_loaded?(module) and function_exported?(module, :provision, 1)
end
```

- [ ] **Step 5: Update `ClaudeCode.provision`**

```elixir
@impl Legend.Core.Harness
def provision(:acp) do
  %{
    detect: %CommandSpec{cmd: "claude-code-acp", args: ["--version"], io: :pipes},
    install: %CommandSpec{cmd: "sh", args: ["-lc", "npm i -g @zed-industries/claude-code-acp"], io: :pipes}
  }
end

def provision(_terminal) do
  %{
    detect: %CommandSpec{cmd: "claude", args: ["--version"], io: :pipes},
    install: %CommandSpec{cmd: "sh", args: ["-lc", "curl -fsSL https://claude.ai/install.sh | sh"], io: :pipes}
  }
end
```

- [ ] **Step 6: Migrate the production caller (controller) to the transport-independent flag**

In `backend/lib/legend_web/controllers/harness_controller.ex`, replace line 16:

```elixir
provisionable: Harness.provisionable?(mod),
```

(The listing has no session transport; `provisionable?` answers "can this harness install itself at all" — the existing `harness_controller_test` assertion `provisionable == true` for claude_code still holds.)

- [ ] **Step 7: Migrate `SessionServer.maybe_provision` to pass the transport**

In `session_server.ex`, change line ~312:

```elixir
case Legend.Core.Harness.provision_for(harness, session.transport) do
```

- [ ] **Step 8: Migrate the existing `harness_provision_test.exs`**

Update its arity-1 calls: `Harness.provision_for(Bare, :terminal)` (nil case) and `Harness.provision_for(Legend.Harnesses.ClaudeCode, :terminal)` (still yields the `claude` detect). Keep the assertion `detect.cmd == "claude"`.

- [ ] **Step 9: Generalize the TestRuntime detect clause so the ACP detect is recognized**

In `backend/test/support/runtimes/test.ex`, change the detect clause from `cmd: "claude"` to match any `--version` detect (so `claude-code-acp --version` also notifies `:detect` and honors the `set_detect` override). This is non-breaking — existing `{:test_runtime, :exec, :detect}` assertions still fire:

```elixir
@impl true
def exec(_handle, %Legend.Core.Runtime.CommandSpec{args: ["--version"]}) do
  notify({:test_runtime, :exec, :detect})
  Application.get_env(:legend, :test_runtime_detect, {:ok, %{stdout: "", status: 1}})
end
```

- [ ] **Step 10: Add the ACP-transport provisioning-dispatch test**

In `session_provisioning_test.exs`, following the existing pattern, create a claude_code/test session with `transport: :acp` and `provisions?: true`, and assert the detect dispatches and (default detect = status 1) the install runs with the ACP install command:

```elixir
test "an acp session provisions the claude-code-acp adapter" do
  TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: nil})
  {:ok, _s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

  assert_receive {:test_runtime, :exec, :detect}, 1000
  assert_receive {:test_runtime, :exec, %CommandSpec{cmd: "sh", args: ["-lc", install]}}, 1000
  assert install =~ "@zed-industries/claude-code-acp"
end
```

(Read the existing provisioning test for the exact setup/teardown + alias conventions before writing.)

- [ ] **Step 11: Run the affected suites**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs test/legend/core/harness_provision_test.exs test/legend/core/agents/session_provisioning_test.exs test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add backend/lib/legend/core/harness.ex backend/lib/legend/harnesses/claude_code.ex backend/lib/legend_web/controllers/harness_controller.ex backend/lib/legend/core/agents/session_server.ex backend/test/support/runtimes/test.ex backend/test/legend/harnesses/claude_code_test.exs backend/test/legend/core/harness_provision_test.exs backend/test/legend/core/agents/session_provisioning_test.exs
git commit -m "feat(harness): transport-aware provisioning (claude-code-acp for cloud ACP)"
```

---

## Task 5: Cloud ACP resume & transport switch start fresh (never reattach the wrong exec)

Phase 2 makes ACP reachable on a runtime that implements `attach/2` (Sprites) for the first time, exposing two reattach hazards: (a) a same-transport ACP resume after a restart would `attach` to the old, already-initialized adapter exec and then write a fresh `initialize` into it (protocol-invalid); (b) a transport switch's `:resume` relaunch would `attach` to the OTHER transport's detached exec. Fix both by gating attach to terminal-only and giving the switch a dedicated `:switch` launch mode that always starts fresh while resuming the conversation at the protocol layer. **`runtime_ref` is NOT cleared** — it stays valid for teardown (no orphaned-sprite leak) and is overwritten by the fresh launch's new ref.

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex` (`start_or_attach`, `conversation_mode`, `build_opts`)
- Modify: `backend/lib/legend/core/agents/session.ex` (`set_transport` → `start_session(session, :switch)`)
- Test: `backend/test/legend/core/agents/session_reattach_test.exs`, `backend/test/legend/core/agents/session_server_acp_test.exs`

**Interfaces:**
- Consumes: `SessionServer.start_session/2` (`:fresh | :resume | :switch`).
- Produces: `:resume` attaches only for `:terminal` sessions; `:switch` always `do_start`s; terminal CLI flags resume the conversation under `:switch` (via `conversation_mode/1`).

- [ ] **Step 1: Pin the EXISTING reattach test to `:terminal` (it tests PTY reattach)**

The existing `session_reattach_test.exs` creates a claude_code/test session with no transport — that resolves to `:acp` (provisions? false), but its intent is terminal reattach-to-live. After the attach gate, ACP won't attach, so pin the transport explicitly. Change line 24:

```elixir
{:ok, s} = Agents.start_session(%{name: "r", harness_id: "claude_code", runtime_id: "test", transport: :terminal})
```

(The rest of the test — `mark_session_running!` with a ref, interrupt, resume, `assert_receive {:test_runtime, :attach, ...}` — is unchanged and still asserts terminal reattach.)

- [ ] **Step 2: Write the failing tests for the gate + switch**

Add to `session_server_acp_test.exs` (it already aliases `TestRuntime` and drives claude_code/test ACP sessions):

```elixir
test "an interrupted ACP session resumes by relaunching (session/load), never attach" do
  TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})
  {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})
  assert_receive {:test_runtime, :start, _spec, _opts}, 1000

  s = Agents.get_session!(s.id)
  Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})
  Legend.Core.Agents.SessionServer.ensure_stopped(s.id)
  {:ok, _} = Agents.interrupt_session(Agents.get_session!(s.id))

  {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))
  assert_receive {:test_runtime, :start, _spec2, _opts2}, 1000
  refute_receive {:test_runtime, :attach, _}, 300
end

test "a transport switch starts a fresh process, never attaching the old transport's exec" do
  TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: nil})
  {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :terminal})
  assert_receive {:test_runtime, :start, _spec, _opts}, 1000

  s = Agents.get_session!(s.id)
  Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "term1"}})
  {:ok, _} = Agents.set_session_transport!(s, %{transport: :acp})

  assert_receive {:test_runtime, :start, _spec2, _opts2}, 1000
  refute_receive {:test_runtime, :attach, _}, 300
end
```

(Use the exact code-interface names: `Agents.mark_session_running!/2`, `Agents.set_session_transport!/2`, `Agents.interrupt_session/1`, `Agents.resume_session/1` — confirmed in `agents.ex`. Read `session_server_acp_test.exs` setup/teardown before adding so capabilities are reset on exit.)

- [ ] **Step 3: Run to verify failure**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs`
Expected: FAIL (ACP resume currently attaches; switch currently uses `:resume` and attaches).

- [ ] **Step 4: Gate the `:resume` attach to terminal + add the `:switch` clause**

In `session_server.ex`:

```elixir
defp start_or_attach(runtime, spec, session, :resume) do
  # Attach-to-live is a terminal-only PTY reconnect. ACP resume must relaunch the
  # adapter and replay via session/load — never reattach to the already-initialized
  # adapter exec.
  if session.transport == :terminal and function_exported?(runtime, :attach, 2) and
       not is_nil(session.runtime_ref) do
    case runtime.attach(session.runtime_ref, start_opts(session)) do
      {:ok, handle} -> {:ok, handle, session.runtime_ref}
      {:error, _} -> do_start(runtime, spec, session)
    end
  else
    do_start(runtime, spec, session)
  end
end

# A transport switch always starts a fresh process for the NEW transport (the
# persisted runtime_ref belongs to the old transport's exec). The conversation is
# resumed at the protocol layer (terminal --resume / ACP session/load).
defp start_or_attach(runtime, spec, session, :switch), do: do_start(runtime, spec, session)

defp start_or_attach(runtime, spec, session, _fresh), do: do_start(runtime, spec, session)
```

- [ ] **Step 5: Normalize the conversation mode for the terminal harness on `:switch`**

The terminal CLI needs `--resume` (not `--session-id`) under a switch. Add a helper and apply it where `build_opts` sets `mode:` (both the `:api` and `:path` clauses):

```elixir
# A switch resumes the conversation under the new transport (terminal --resume /
# ACP session/load) but with a fresh process — so the harness sees :resume.
defp conversation_mode(:switch), do: :resume
defp conversation_mode(mode), do: mode
```

In each `build_opts` clause replace `mode: mode` with `mode: conversation_mode(mode)`. (ACP's `start_transport` keys load on `conversation_id`, so it is already correct; only the terminal harness reads `mode`.)

- [ ] **Step 6: Make `set_transport` relaunch with `:switch`**

In `backend/lib/legend/core/agents/session.ex`, in the `update :set_transport` action's `after_transaction`, change the relaunch call:

```elixir
case Legend.Core.Agents.SessionServer.start_session(session, :switch) do
```

(Leave the lifecycle resets and `ensure_stopped` before_action as-is. Do NOT clear `runtime_ref` — it must stay valid for teardown; the fresh `do_start` overwrites it with the new transport's ref.)

- [ ] **Step 7: Run the resume + switch + reattach tests**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs test/legend/core/agents/session_reattach_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full agents suite**

Run: `cd backend && mix test test/legend/core/agents/`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_server_acp_test.exs backend/test/legend/core/agents/session_reattach_test.exs
git commit -m "fix(sessions): ACP resume + transport switch start fresh (gate attach to terminal)"
```

---

## Task 6: Frontend — terminal-first hint for cloud rich-capable sessions

A cloud Claude Code session opens in Terminal with the existing `rich ⇄ term` toggle. Add a subtle hint so the user knows to authenticate, then switch. Purely additive.

**Files:**
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte`
- Test: `cd frontend && bun run check`

**Interfaces:**
- Consumes: `session.transport`, `session.runtime_id`, `harness.transports` (already in `SessionPane`).

- [ ] **Step 1: Choose the cloud signal**

The runtimes API serializes the Elixir key with a literal `?` (`"provisions?"`), so `capabilities.provisions` (no `?`) reads `undefined` on the frontend. Do NOT rely on it. Gate the hint on `transport === 'terminal'` AND the harness `transports` includes `'acp'` AND `session.runtime_id !== 'local_pty'` (the correct signal for the current runtime set), with a `// TODO: switch to a capabilities-based cloud gate when more runtimes exist`. Read `frontend/src/lib/sessions.ts` to confirm the field names.

- [ ] **Step 2: Add the hint**

In `SessionPane.svelte`, when the body is the Terminal and that gate holds, render a subtle strip with Legend tokens (e.g. `text-micro text-ink-subtle`), copy like: `Sign in to Claude Code in the terminal, then switch to rich for the structured view.` Reuse the existing transport-toggle handler/label; no raw shadcn/hex classes.

- [ ] **Step 3: Run the check**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 4: Verify live (CDP click-through)**

Drive Chrome via CDP over a Bun WebSocket (no Playwright) to confirm the hint shows for a cloud session and is absent for a local one. If a cloud session can't be created without auth, temporarily force the props to verify the conditional, then confirm the local case shows no hint. [[frontend-live-verification-cdp]]

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/sessions/SessionPane.svelte
git commit -m "feat(fe): terminal-first hint for cloud rich-capable sessions"
```

---

## Task 7: Documentation — ARCHITECTURE.md, spec status

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md`

- [ ] **Step 1: Update the spec**

Mark Phase 2 built. In "Cloud/remote (Phase 2 — additive)" record the verified non-TTY wire format (1-byte stream-id demux: `0x00` stdin, `0x01` stdout, `0x02` stderr, `0x03` exit; `tty=false`). Resolve verify-at-plan-time #4 (invocation: `npm i -g @zed-industries/claude-code-acp`) and note #5 (sprite-FS conversation persistence) is confirmed in the manual bring-up. Record the **terminal-first auth** decision and that **ACP resume/switch always relaunch + `session/load`** (never reattach).

- [ ] **Step 2: Update ARCHITECTURE.md**

Record: `Sprites.Exec` `:pipes` mode (Docker-style stream-id demux) selected by `CommandSpec.io`; transport-aware provisioning (`provision/1`, `provisionable?/1`); runtime-aware default transport; the `:switch` launch mode (transport switch starts fresh, conversation resumed at the protocol layer; `:resume` attach gated to terminal). Keep the spec index in sync. **Accepted caveat:** a transport switch on a cloud runtime leaves the pre-switch exec **detached** in the sprite until the sprite hibernates/is deleted — the sprite itself is still torn down on destroy (runtime_ref stays valid; it is not cleared).

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md
git commit -m "docs(acp): phase 2 cloud built — sprites :pipes, provisioning, auth model"
```

---

## Manual acceptance (live bring-up — needs the user's Claude auth)

Not automated; the end-to-end confirmation, run by the user on a machine with `SPRITES_TOKEN` + a Claude account:

1. New session → harness **Claude Code**, runtime **sprites** → opens in **terminal** (`:provisioning` only if `claude` ever needs install, then `:running`).
2. Authenticate in the terminal (`claude` / `claude setup-token`); confirm it persists.
3. Click **rich** → `:provisioning` (installs `claude-code-acp`) → ACP handshake → `session/load` repaints the conversation the TUI started.
4. The agent can call Legend MCP tools (`list_agents`, `read_messages`) — confirms the signal bus + library reach the backend over the reverse tunnel from inside the sprite.
5. Close the laptop / restart the backend → resume → confirm `session/load` repaint and continued operation (validates sprite-FS conversation persistence across hibernation, spec open-unknown #5).
6. Delete the session → sprite torn down (`get_sprite` 404).

Report deviations — especially whether `claude-code-acp` authenticates from the persisted `~/.claude` creds and whether cloud `session/load` repaints correctly.

## Self-review notes

- **TTY path untouched:** every `:pipes` behavior is gated on `spec.io`/the session_info `tty` field; `demux_output(_, false)`/`encode_stdin(_, false)` are identity-for-TTY.
- **MCP/tunnel/`session/load`:** already wired in `SessionServer` (`acp_mcp_servers/3`, `maybe_open_tunnel`, `start_transport(:acp)` keying load on `conversation_id`) — no new code; exercised by the manual bring-up.
- **`Exec.run` now honors `io`:** existing `io: :pipes` callers (`SpriteProxy` bridge commands, provisioning) switch from `tty=true` to `tty=false`; they consume exit status / combined output, preserved by the stderr-merged `run/3` collector. Real coverage: the offline `spawn_query` tty=false assertion (Task 1) + the `:live_sprites` round-trip (Task 2) + the gated bridge path in the manual bring-up. (The SpriteProxy unit tests are offline and do NOT exercise `Exec.run`.)
- **No orphaned-sprite leak:** the switch keeps `runtime_ref` (overwritten by the fresh launch; preserved on a failed switch), so `maybe_teardown_runtime` always reaches the sprite on destroy.
- **Resume/switch correctness:** ACP always relaunches (`:resume` gate + `:switch` → `do_start`); terminal restart-resume still reattaches (`session_reattach_test` pinned to `:terminal`).
```
