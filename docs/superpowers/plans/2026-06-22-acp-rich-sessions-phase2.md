# ACP Rich Sessions — Phase 2 (Cloud / Sprites) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run an ACP (rich-UI) Claude Code session on a sprites.dev cloud sandbox — the adapter speaks JSON-RPC over a non-PTY (`:pipes`) WSS exec, reaches the Legend MCP signal bus + library over the existing reverse tunnel, and resumes via `session/load`.

**Architecture:** The orchestration is already transport- and location-agnostic from Phase 1 (the `SessionServer` opens the tunnel for any runtime that declares one, and `acp_mcp_servers/3` already emits the cloud HTTP MCP entry at `base_url <> "/api/mcp"`). Phase 2 fills the one real gap: `Legend.Sprites.Exec` gains a `:pipes` mode (Docker-style 1-byte stream-id demux over the WSS exec, `tty=false`), the ACP adapter (`claude-code-acp`) is provisioned into the sprite, and cloud Claude Code defaults to the `:terminal` transport so the human authenticates once in the PTY before switching to the rich (`:acp`) view on the same persisted sprite/conversation.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 / AshSqlite; `Mint.WebSocket` (sprites WSS); SvelteKit 2 / Svelte 5 runes / Tailwind v4 (frontend); sprites.dev cloud sandbox.

## Verified facts (live against api.sprites.dev, 2026-06-22)

These are the protocol/environment constants this plan depends on. They were captured by a live throwaway-sprite probe and are the authority for the wire format (the prior `Sprites.Exec` moduledoc documented only `tty=true`).

**Non-TTY (`tty=false`) exec wire format — Docker-style 1-byte stream-id demux:**
- Spawn query is identical to the TTY path except `tty=false` (omitting `tty` also yields `tty=false`); `stdin=true&detachable=true` still apply. `rows`/`cols` are irrelevant under `tty=false` (server reports `cols:0,rows:0`).
- The leading TEXT frames are unchanged: optional `{"type":"debug",...}` lines, then `{"type":"session_info","session_id":"<id>",...,"tty":false}` (same reattach handle).
- **Output BINARY frames carry a 1-byte stream-id prefix:**
  - `0x01` + payload → **stdout**
  - `0x02` + payload → **stderr**
  - `0x03` + 1 byte → exit-status control frame (the exit code as a byte; redundant with the TEXT exit frame below — ignore it)
- **stdin BINARY frames must be prefixed with `0x00`** (`<<0>> <> data`). Raw (unprefixed) stdin bytes are silently dropped.
- Exit is ALSO signalled by the existing TEXT frame `{"type":"exit","exit_code":N}` (the path `Sprites.Exec` already handles), followed by WS CLOSE 1000.
- **TTY mode is unchanged:** BINARY frames are raw terminal bytes with **no** prefix; stdin is raw bytes; this plan must not alter that path.

**Default sprite image (Ubuntu 25.10) toolchain — already present:**
- `node` v22.20.0, `npm` 11.16.0, `npx` (`/.sprite/bin/npx`), `claude` 2.1.168 (Claude Code).
- **`claude-code-acp` is MISSING** → install with `npm i -g @zed-industries/claude-code-acp` (detect with `claude-code-acp --version`).
- Because `claude` is already installed, the existing terminal `provision/0` detect passes with no install on a fresh sprite.

## Global Constraints

- **Clean over compatibility.** Legend is early-stage with no external consumers; replace signatures outright and migrate all callers rather than adding shims (e.g. `provision/0` → `provision/1`, `default_transport/1` → `default_transport/2`). [[clean-over-compat-early-stage]]
- **TTY path is sacred.** The existing `tty=true` exec behavior (terminal sessions, local + cloud) must be byte-for-byte unchanged. All `:pipes` behavior is gated on `spec.io == :pipes` / the session_info `"tty"` field.
- **No raw bytes into an ACP pipe beyond the protocol.** ACP stdin is JSON-RPC frames written by `Acp.Connection` via `runtime.write/2`; the only transformation `Sprites.Exec` applies is the `<<0>>` stdin stream-id prefix. Agent-controllable strings that reach a PTY are already sanitized at `Terminal.nudge_line/3`; nothing in this plan introduces a new PTY-injection vector.
- **Registry ids stay strings.** Never `String.to_atom/1` on a harness/runtime/tunnel/transport id sourced from user input.
- **Auth model = terminal-first, then switch (no stored model credential).** Cloud Claude Code defaults to `:terminal`; the human authenticates once in the PTY; credentials persist in the sprite's `~/.claude`; the user flips to `rich` (ACP `session/load` over the same persisted sprite). Legend stores no model credential.
- **Provisioning runs on every launch/relaunch** (including the `set_transport` switch), so the ACP adapter is installed lazily when the user first switches a cloud session to rich.
- **Frontend token discipline:** feature code uses Legend tokens (`text-ink-*`, `bg-shell/app/panel`, `text-micro…title`) + shell primitives; never raw shadcn neutral classes / ad-hoc hex / ad-hoc `text-[Npx]`.
- **Verification gates:** backend `cd backend && mix precommit` (compile --warnings-as-errors + format + test) must be green before finishing; frontend `cd frontend && bun run check` must be 0 errors / 0 warnings. Live cloud tests are `@tag :live_sprites` and excluded from the default run.

---

## Task 1: `Sprites.Exec` — `:pipes` wire-format pure helpers

Extract the wire-format decisions into pure, offline-testable functions before touching the GenServer. This keeps the protocol logic unit-tested without a live connection (matching the existing offline `exec_test.exs` pattern).

**Files:**
- Modify: `backend/lib/legend/sprites/exec.ex`
- Test: `backend/test/legend/sprites/exec_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Runtime.CommandSpec` (`%CommandSpec{io: :pty | :pipes}`).
- Produces (new public/`@doc false` pure functions on `Legend.Sprites.Exec`):
  - `spawn_query/2` — now io-aware: a `%CommandSpec{io: :pipes}` yields `tty=false`; `:pty`/default yields `tty=true` (unchanged).
  - `demux_output/2 :: (binary(), pipes? :: boolean()) -> {:stdout, binary()} | {:stderr, binary()} | {:exit, non_neg_integer()} | :ignore` — splits a BINARY output frame.
  - `encode_stdin/2 :: (binary(), pipes? :: boolean()) -> binary()` — `pipes?` prefixes `<<0>>`; else passes through.

- [ ] **Step 1: Write failing tests for the io-aware spawn query**

Add to `backend/test/legend/sprites/exec_test.exs`:

```elixir
test "spawn_query/2 uses tty=false for an :pipes spec" do
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: FAIL (current `spawn_query` hardcodes `tty=true`).

- [ ] **Step 3: Make `spawn_query/2` io-aware**

In `backend/lib/legend/sprites/exec.ex`, change the `fixed` list in `spawn_query/2` so `tty` reflects `spec.io`. The `CommandSpec` struct is already destructured; add `io: io` to the match and compute the flag:

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

- [ ] **Step 4: Run to verify the spawn-query tests pass**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS (including the pre-existing `tty=true` default test).

- [ ] **Step 5: Write failing tests for `demux_output/2` and `encode_stdin/2`**

Add to `exec_test.exs`:

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

- [ ] **Step 7: Implement the pure helpers**

Add to `backend/lib/legend/sprites/exec.ex` (place near the other public helpers, above the GenServer API):

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

- [ ] **Step 8: Run to verify all Task-1 tests pass**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/sprites/exec.ex backend/test/legend/sprites/exec_test.exs
git commit -m "feat(sprites): io-aware spawn query + pipes demux/stdin helpers"
```

---

## Task 2: `Sprites.Exec` — wire the GenServer into `:pipes` mode

Make the live exec process use the Task-1 helpers: track whether this exec is pipes/tty, demux output frames to the right owner message, prefix stdin, and merge stderr into the `run/3` result so provisioning error reporting still works.

**Files:**
- Modify: `backend/lib/legend/sprites/exec.ex`
- Test: `backend/test/legend/sprites/exec_test.exs` (gated live test) and a new offline test for the `run/3` collector.

**Interfaces:**
- Consumes: `demux_output/2`, `encode_stdin/2`, `spawn_query/2` (Task 1).
- Produces: the `Legend.Core.Runtime` message contract unchanged for the owner — stdout → `{:runtime_output, bin}`, stderr → `{:runtime_stderr, bin}` (matching `LocalPty :pipes`), exit → `{:runtime_exit, code}`. `start/3`, `attach/3`, `run/3`, `write/2` signatures unchanged.

- [ ] **Step 1: Add `pipes?` to the GenServer state, seeded from the spec / session_info**

In `init/1`, seed `pipes?` from the spec's `io` for `:spawn`/`:run` (the spec is `arg`); for `:attach` seed `false` and let session_info override (the `tty` field always arrives before any binary frame). Add `pipes?: false` to the state map and set it:

```elixir
def init({mode, name, arg, opts}) do
  owner = Map.fetch!(opts, :owner)

  pipes? =
    case mode do
      :attach -> false
      _ -> match?(%CommandSpec{io: :pipes}, arg)
    end

  state = %{
    name: name,
    owner: owner,
    conn: nil,
    websocket: nil,
    ref: nil,
    exec_id: nil,
    exited?: false,
    pipes?: pipes?
  }
  ...
```

- [ ] **Step 2: Capture the authoritative `tty` from `session_info`**

In `dispatch_frame/2`'s `session_info` clause, set `pipes?` from the frame's `"tty"` field (authoritative for both spawn and attach):

```elixir
{:ok, %{"type" => "session_info", "session_id" => id} = info} ->
  %{state | exec_id: state.exec_id || to_string(id), pipes?: info["tty"] == false}
```

- [ ] **Step 3: Demux output frames through the owner contract**

Replace the `dispatch_frame({:binary, data}, state)` clause so it routes via `demux_output/2`:

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

(`demux_output(data, false)` returns `{:stdout, data}`, so TTY behavior is byte-for-byte unchanged.)

- [ ] **Step 4: Prefix stdin writes**

Change the write cast to encode stdin per mode:

```elixir
def handle_cast({:write, data}, state) do
  {:noreply, send_frame(state, {:binary, encode_stdin(data, state.pipes?)})}
end
```

- [ ] **Step 5: Write a failing offline test for the `run/3` collector merging stderr**

The provisioning error path reports `%{stdout: out}`; under pipes, install errors land on stderr, so `collect_run/3` must accumulate both streams. Add an offline test that drives the collector directly:

```elixir
test "collect_run accumulates stdout and stderr into the combined result" do
  parent = self()
  ref = make_ref()
  collector = spawn(fn -> send(parent, {:started}) ; Legend.Sprites.Exec.collect_run(parent, ref, "") end)
  assert_receive {:started}
  send(collector, {:runtime_output, "OUT"})
  send(collector, {:runtime_stderr, "ERR"})
  send(collector, {:runtime_exit, 3})
  assert_receive {^ref, 3, combined}
  assert combined =~ "OUT"
  assert combined =~ "ERR"
end
```

(Promote `collect_run/3` to a public `@doc false` function so the test can call it; it currently is `defp`.)

- [ ] **Step 6: Run to verify failure**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: FAIL (collector ignores `{:runtime_stderr, _}`).

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

This exercises the real wire format end-to-end without any model auth (it runs `sh`, not the adapter). Add to `exec_test.exs`:

```elixir
@tag :live_sprites
test "live: non-TTY exec demuxes stdout/stderr and reports the exit code" do
  if System.get_env("SPRITES_TOKEN") in [nil, ""], do: flunk("set SPRITES_TOKEN for :live_sprites")
  name = "lt-pipes-#{System.system_time(:second)}"
  {:ok, _} = Legend.Sprites.Client.create_sprite(name)
  Process.sleep(3_000)

  spec = %CommandSpec{
    cmd: "sh",
    args: ["-c", "printf OUT; printf ERR 1>&2; exit 5"],
    io: :pipes
  }

  result = Legend.Sprites.Exec.run(name, spec, 60_000)
  Legend.Sprites.Client.delete_sprite(name)

  assert {:ok, %{stdout: combined, status: 5}} = result
  assert combined =~ "OUT"
  assert combined =~ "ERR"
end
```

Confirm `:live_sprites` is excluded by default. Check `backend/test/test_helper.exs`; if it does not already `ExUnit.configure(exclude: [:live_sprites])` (or `:live`), add `:live_sprites` to the excludes so `mix test` stays offline. Note the chosen tag name in the commit message.

- [ ] **Step 10: Run the offline suite (live test excluded) + the live test explicitly**

Run (offline): `cd backend && mix test test/legend/sprites/exec_test.exs`
Expected: PASS, with the live test skipped/excluded.

Run (live, this machine has `SPRITES_TOKEN`): `cd backend && mix test test/legend/sprites/exec_test.exs --only live_sprites`
Expected: PASS (creates a throwaway sprite, asserts `OUT`/`ERR`/status 5, deletes it).

- [ ] **Step 11: Commit**

```bash
git add backend/lib/legend/sprites/exec.ex backend/test/legend/sprites/exec_test.exs backend/test/test_helper.exs
git commit -m "feat(sprites): :pipes exec mode (stream-id demux, stdin prefix, stderr-merged run)"
```

---

## Task 3: Transport-aware provisioning (install `claude-code-acp` for cloud ACP)

A cloud session switching to `:acp` needs the adapter in the sprite. Make the harness `provision` callback transport-aware so ACP launches install `claude-code-acp` while terminal launches keep installing `claude`.

**Files:**
- Modify: `backend/lib/legend/core/harness.ex` (callback + `provision_for`)
- Modify: `backend/lib/legend/harnesses/claude_code.ex`
- Modify: `backend/lib/legend/harnesses/hermes.ex` (only if it implements `provision/0`)
- Modify: `backend/lib/legend/core/agents/session_server.ex` (`maybe_provision` passes the transport)
- Test: `backend/test/legend/harnesses/claude_code_test.exs` (create if absent) and `backend/test/legend/core/agents/session_provisioning_test.exs`

**Interfaces:**
- Consumes: `session.transport` (`:terminal | :acp`).
- Produces:
  - `@callback provision(transport :: :terminal | :acp) :: %{detect: CommandSpec.t(), install: CommandSpec.t()} | nil` (replaces `provision/0`).
  - `Legend.Core.Harness.provision_for(module, transport) :: %{detect, install} | nil`.
  - `ClaudeCode.provision(:terminal)` → `claude`; `ClaudeCode.provision(:acp)` → `claude-code-acp`.

- [ ] **Step 1: Write the failing harness test**

Create/extend `backend/test/legend/harnesses/claude_code_test.exs`:

```elixir
defmodule Legend.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: true
  alias Legend.Harnesses.ClaudeCode

  test "provision/1 targets claude for terminal, claude-code-acp for acp" do
    term = ClaudeCode.provision(:terminal)
    assert term.detect.cmd == "claude"

    acp = ClaudeCode.provision(:acp)
    assert acp.detect.args |> Enum.join(" ") =~ "claude-code-acp" or acp.detect.cmd =~ "claude-code-acp"
    assert acp.install.args |> Enum.join(" ") =~ "@zed-industries/claude-code-acp"
    assert acp.install.io == :pipes
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs`
Expected: FAIL (`provision/1` undefined).

- [ ] **Step 3: Update the behaviour**

In `backend/lib/legend/core/harness.ex`, change the callback and helper to take a transport:

```elixir
@callback provision(transport :: Definition.transport()) ::
            %{
              detect: Legend.Core.Runtime.CommandSpec.t(),
              install: Legend.Core.Runtime.CommandSpec.t()
            }
            | nil
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
```

- [ ] **Step 4: Update `ClaudeCode.provision`**

In `backend/lib/legend/harnesses/claude_code.ex`:

```elixir
@impl Legend.Core.Harness
def provision(:acp) do
  %{
    detect: %CommandSpec{cmd: "claude-code-acp", args: ["--version"], io: :pipes},
    install: %CommandSpec{
      cmd: "sh",
      args: ["-lc", "npm i -g @zed-industries/claude-code-acp"],
      io: :pipes
    }
  }
end

def provision(_terminal) do
  %{
    detect: %CommandSpec{cmd: "claude", args: ["--version"], io: :pipes},
    install: %CommandSpec{
      cmd: "sh",
      args: ["-lc", "curl -fsSL https://claude.ai/install.sh | sh"],
      io: :pipes
    }
  }
end
```

- [ ] **Step 5: Update any other `provision/0` implementers**

Run: `cd backend && grep -rn "def provision" lib/`
For each implementer (e.g. Hermes if present), change `def provision do` → `def provision(_transport) do` (or transport-specific clauses). If a harness only runs terminal, a single `def provision(_transport)` clause is correct.

- [ ] **Step 6: Update `SessionServer.maybe_provision` to pass the transport**

In `backend/lib/legend/core/agents/session_server.ex`, change the `provision_for` call:

```elixir
case Legend.Core.Harness.provision_for(harness, session.transport) do
  nil ->
    {:error, "harness #{session.harness_id} has no installer for this runtime"}
  %{detect: detect, install: install} ->
    ...
end
```

- [ ] **Step 7: Write/extend the provisioning-dispatch test for the ACP transport**

In `backend/test/legend/core/agents/session_provisioning_test.exs`, add a case that a `transport: :acp` session on a provisioning runtime detects/installs the ACP adapter. Follow the existing pattern (the test runtime captures `exec` calls; assert the detect `CommandSpec` carries `claude-code-acp`). Read the existing test for the exact fake-harness/test-runtime wiring before writing.

- [ ] **Step 8: Run the provisioning + harness tests**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs test/legend/core/agents/session_provisioning_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/core/harness.ex backend/lib/legend/harnesses/ backend/lib/legend/core/agents/session_server.ex backend/test/legend/harnesses/claude_code_test.exs backend/test/legend/core/agents/session_provisioning_test.exs
git commit -m "feat(harness): transport-aware provisioning (claude-code-acp for cloud ACP)"
```

---

## Task 4: Runtime-aware default transport (cloud Claude Code opens in terminal)

So the human can authenticate, a provisioning (cloud) runtime defaults a fresh ACP-capable session to `:terminal`; local stays on the harness default (`:acp` for Claude Code).

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (`default_transport`, `:start` change)
- Test: `backend/test/legend/core/agents/session_test.exs` (create if absent; otherwise the closest session-action test)

**Interfaces:**
- Consumes: `Legend.Core.Runtime.capabilities/1` (`%{provisions?: boolean()}`), harness `transports`.
- Produces: `default_transport(harness_id, runtime_id) :: :terminal | :acp` (replaces `default_transport/1`).

- [ ] **Step 1: Write the failing test**

```elixir
test "default_transport prefers terminal on a provisioning (cloud) runtime, acp locally" do
  alias Legend.Core.Agents.Session
  assert Session.default_transport("claude_code", "local_pty") == :acp
  assert Session.default_transport("claude_code", "sprites") == :terminal
  # A terminal-only harness is :terminal everywhere.
  assert Session.default_transport("hermes", "sprites") == :terminal
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: FAIL (`default_transport/2` undefined).

- [ ] **Step 3: Implement `default_transport/2`**

In `backend/lib/legend/core/agents/session.ex`:

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

# A provisioning runtime is a fresh remote box that needs interactive (PTY)
# first-run auth, so an ACP-capable session starts in :terminal until the human
# has authenticated; they then switch to :acp on the same persisted sprite.
defp remote_auth_runtime?(runtime_id) do
  case Legend.Core.Runtime.Registry.fetch(runtime_id) do
    {:ok, rmod} -> Legend.Core.Runtime.capabilities(rmod).provisions?
    :error -> false
  end
end
```

- [ ] **Step 4: Update the `:start` change to pass `runtime_id`**

In the `create :start` action's transport-default change, resolve the runtime id from the changeset (it carries the supplied value or the `"local_pty"` attribute default) and pass it:

```elixir
hid = Ash.Changeset.get_attribute(changeset, :harness_id)
rid = Ash.Changeset.get_attribute(changeset, :runtime_id)
Ash.Changeset.force_change_attribute(changeset, :transport, default_transport(hid, rid))
```

- [ ] **Step 5: Run the test**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the broader session-action tests to confirm no regression**

Run: `cd backend && mix test test/legend/core/agents/`
Expected: PASS (existing tests that create sessions without a runtime still default to local → `:acp` for Claude Code).

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_test.exs
git commit -m "feat(sessions): runtime-aware default transport (cloud opens terminal-first)"
```

---

## Task 5: `set_transport` clears `runtime_ref` (cloud switch starts fresh, not attach-to-old-exec)

On a transport switch, the persisted `runtime_ref` belongs to the OTHER transport's exec session. Because sprites execs are `detachable=true`, the `:resume` relaunch could wrongly reattach to the old (e.g. terminal) exec and feed its bytes into the new transport's decoder. Clearing `runtime_ref` forces the relaunch to start a fresh process for the new transport.

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (`set_transport` action)
- Test: `backend/test/legend/core/agents/session_server_acp_test.exs` or `session_reattach_test.exs` (whichever owns transport-switch coverage)

**Interfaces:**
- Consumes: the `:set_transport` action; `SessionServer.start_or_attach/4` (`:resume` with nil `runtime_ref` → `do_start`).
- Produces: after `set_transport`, `session.runtime_ref == nil`; the relaunch starts a fresh process and persists a new ref.

- [ ] **Step 1: Write the failing test**

Assert that `set_transport` nils the persisted `runtime_ref`. Drive it on the test runtime (no real sprite):

```elixir
test "set_transport clears runtime_ref so the relaunch starts fresh, not attach" do
  {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :terminal})
  # Simulate a persisted reattach ref from the first (terminal) launch.
  {:ok, s} = Agents.set_session_runtime_ref(s, %{"sprite" => s.id, "exec_id" => "old"})
  {:ok, switched} = Agents.set_transport(s, :acp)
  assert switched.runtime_ref == nil
end
```

If no `set_session_runtime_ref` interface exists, set the ref via the existing `:mark_running` action (`accept [:runtime_ref]`) instead — read `agents.ex` for the available code interfaces before writing the test, and use what is already there.

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs`
Expected: FAIL (`runtime_ref` survives the switch).

- [ ] **Step 3: Clear `runtime_ref` in the `set_transport` action**

In `backend/lib/legend/core/agents/session.ex`, add to the `update :set_transport` block (alongside the existing `set_attribute` lifecycle resets):

```elixir
# The old runtime_ref belongs to the PRE-switch transport's exec session.
# sprites execs are detachable, so a :resume relaunch could reattach to that
# stale exec and feed its bytes into the new transport's decoder. Clear it so
# start_or_attach falls through to a fresh do_start; the new launch persists a
# new ref. (LocalPty has no attach/2, so this is a no-op there.)
change set_attribute(:runtime_ref, nil)
```

- [ ] **Step 4: Run the test**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full agents suite to confirm switch/resume still behave**

Run: `cd backend && mix test test/legend/core/agents/`
Expected: PASS (terminal↔acp switch tests, reattach-on-restart tests).

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_server_acp_test.exs
git commit -m "fix(sessions): clear runtime_ref on transport switch (cloud starts fresh)"
```

---

## Task 6: Frontend — terminal-first hint for cloud rich-capable sessions

A cloud Claude Code session opens in the Terminal view with the existing `rich ⇄ term` toggle. Add a subtle, dismissible-by-context hint so the user knows to authenticate, then switch to rich. Purely additive; no change to the switch mechanics.

**Files:**
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte`
- Test: `cd frontend && bun run check`

**Interfaces:**
- Consumes: `session.transport`, `session.runtime_id`, `harness.transports` (already available in `SessionPane`).
- Produces: a one-line hint rendered above/within the terminal body when `transport === 'terminal'` AND the harness also speaks `'acp'` AND the runtime is a provisioning/cloud runtime.

- [ ] **Step 1: Determine the cloud signal available on the frontend**

Read `frontend/src/lib/sessions.ts` and the runtimes API client. If the frontend already knows a runtime's `provisions?`/capabilities (via `/api/runtimes`), gate the hint on that. If not, gate on `runtime_id !== 'local_pty'` (the simplest correct signal for the current two-runtime set) and leave a `// TODO` noting a capabilities-based gate when more runtimes exist. Pick the approach the existing code best supports; do not add a new endpoint for this hint.

- [ ] **Step 2: Add the hint**

In `SessionPane.svelte`, when the body is the Terminal and the harness speaks both transports and the runtime is cloud, render a subtle strip using Legend tokens (e.g. `text-micro text-ink-subtle bg-panel`), with copy like: `Sign in to Claude Code in the terminal, then switch to **rich** for the structured view.` Use the existing transport-toggle handler/label; do not introduce raw shadcn/hex classes.

- [ ] **Step 3: Run the check**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 4: Verify live (CDP click-through)**

Per the user's verification preference, drive Chrome via CDP over a Bun WebSocket (no Playwright) to confirm the hint renders on a cloud session and is absent on a local one. [[frontend-live-verification-cdp]] If a cloud session can't be created without auth, verify the conditional by temporarily forcing the props in the component and confirm the local case shows no hint.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/sessions/SessionPane.svelte
git commit -m "feat(fe): terminal-first hint for cloud rich-capable sessions"
```

---

## Task 7: Documentation — ARCHITECTURE.md, spec status, ledger

Record the built state and the verified facts so the next reader doesn't re-derive them.

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md`

- [ ] **Step 1: Update the spec**

In `2026-06-20-acp-rich-sessions-design.md`: mark Phase 2 built; in "Cloud/remote (Phase 2 — additive)" note the `Sprites :pipes` mode is implemented with the verified non-TTY wire format (1-byte stream-id demux: `0x00` stdin, `0x01` stdout, `0x02` stderr, `0x03` exit; `tty=false`). Resolve the relevant "Verify-at-plan-time" unknowns (#4 invocation specifics: `npm i -g @zed-industries/claude-code-acp`; #5 sprite-FS persistence: to be confirmed in the manual bring-up). Record the **terminal-first auth** decision (cloud defaults to `:terminal`; switch to `:acp` after PTY auth; no stored credential).

- [ ] **Step 2: Update ARCHITECTURE.md**

Record: `Sprites.Exec` now has a `:pipes` mode (Docker-style stream-id demux) selected by `CommandSpec.io`; transport-aware provisioning (`provision/1`); runtime-aware default transport; `set_transport` clears `runtime_ref` (cloud switch starts fresh). Keep the spec index in sync. Note the accepted caveat: a transport switch on a cloud runtime leaves the pre-switch exec detached in the sprite until the sprite hibernates/is deleted.

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md docs/superpowers/specs/2026-06-20-acp-rich-sessions-design.md
git commit -m "docs(acp): phase 2 cloud built — sprites :pipes, provisioning, auth model"
```

---

## Manual acceptance (live bring-up — needs the user's Claude auth)

Not an automated task; this is the end-to-end confirmation, run by the user on a machine with `SPRITES_TOKEN` and a Claude account:

1. New session → harness **Claude Code**, runtime **sprites** → it opens in the **terminal** (`:provisioning` if `claude` ever needs install, then `:running`).
2. Authenticate in the terminal (`claude` / `claude setup-token`); confirm it persists in the sprite.
3. Click **rich** → expect `:provisioning` (installs `claude-code-acp`) → ACP handshake → `session/load` repaints the conversation the TUI started.
4. Verify the agent can call the Legend MCP tools (e.g. `list_agents`, `read_messages`) — confirms the signal bus + library reach the backend over the reverse tunnel from inside the sprite.
5. Close the laptop / restart the backend → resume → confirm `session/load` repaint and continued operation (validates sprite-FS conversation persistence across hibernation, spec open-unknown #5).
6. Delete the session → sprite is torn down (`get_sprite` 404).

Report any deviation (especially: does `claude-code-acp` authenticate from the persisted `~/.claude` creds, and does cloud `session/load` repaint correctly).

## Self-review notes

- **TTY path untouched:** every `:pipes` behavior is gated on `spec.io`/the session_info `tty` field; `demux_output(_, false)` and `encode_stdin(_, false)` are identity-for-TTY.
- **MCP/tunnel/`session/load`:** already wired in `SessionServer` (`acp_mcp_servers/3`, `maybe_open_tunnel`, `start_transport(:acp)` keying load on `conversation_id`) — no new code, exercised by the manual bring-up.
- **Breakage risk — `Exec.run` now honors `io`:** existing `io: :pipes` callers (`SpriteProxy` bridge commands, provisioning) switch from `tty=true` to `tty=false`; they only consume exit status / combined output, which the stderr-merged `run/3` collector preserves. Covered by the SpriteProxy tests + the offline collector test; confirm `mix precommit` and the `--only live_sprites` run are green.
