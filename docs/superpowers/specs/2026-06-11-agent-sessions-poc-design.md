# Agent Sessions PoC — Design

**Date:** 2026-06-11
**Status:** Approved
**Builds on:** the legend scaffold (see `2026-06-10-legend-scaffold-design.md`)

## Vision context

Legend is an orchestrator platform for AI agents: a unified interface for Claude Code, Hermes, OpenClaw, and other agent harnesses, with a composable architecture so new harnesses, runtimes, and capabilities arrive as plugins. The full vision (multi-agent rooms, model registry, shared file storage, cloud sync, public plugin API) decomposes into sub-projects; this spec covers the first one — the spine everything else stands on.

**This PoC: agent sessions.** From Legend's UI (web or desktop), start a session by picking a harness, interact with the agent in an embedded terminal, navigate away, come back, and reattach with scrollback intact. Multiple sessions run concurrently.

## Goals

1. Start, use, stop, list, and reattach to agent sessions through Legend's UI.
2. Two working terminal harnesses — **Claude Code** and **Hermes** — proving the harness abstraction with two real implementations.
3. Plugin seams that are real: harness and runtime are behaviour-based extension points with config-listed registries, shaped so ACP harnesses, a native (Jido) harness, and cloud-sandbox runtimes drop in later without reworking the core.

## Non-goals (recorded as extension architecture, not built)

- ACP harnesses and the rich web UI (structured prompts, tool calls, diffs).
- Native in-BEAM harnesses (Jido chat agent).
- Cloud/sandbox runtimes; reverse tunnels for remote local machines.
- Agent-to-agent communication, rooms, handoffs, workgroups.
- Auth/multi-user (single local user; backend binds loopback).
- A public plugin packaging/distribution story.

## Architecture

Two orthogonal plugin axes, both Elixir behaviours with config-listed module registries (same pattern as `ash_domains`):

- **Harness** — *which agent*: identity, metadata, and how to talk to it.
- **Runtime** — *where it executes*: local PTY now; Docker, Fly Machine, hosted sandbox, reverse-tunnel later.

A **Session** composes one harness with one runtime and is the unit users see, list, and attach to.

### Data flow (live session)

```
xterm.js (SvelteKit, browser or Tauri webview)
   ↕ Phoenix Channel "session:<id>"   input/resize down, output/exit/status up
SessionServer (GenServer per session: scrollback buffer, PubSub broadcast)
   ↕ Legend.Runtime behaviour
LocalPty runtime → PTY → agent CLI (claude / hermes)
```

Sessions survive browser refresh and navigation (the GenServer and PTY keep running; reattach replays the buffer). Sessions do **not** survive backend restart — an accepted PoC limitation, surfaced honestly in the UI.

### Harness kinds and IO modes

`Legend.Harness.definition/0` returns a `kind`. The enum is defined now; only `:terminal` is implemented in the PoC:

| Kind | Transport | Rendering | PoC |
|---|---|---|---|
| `:terminal` | PTY byte stream | xterm.js — universal fallback for any CLI | ✅ Claude Code, Hermes |
| `:acp` | subprocess over plain pipes, JSON-RPC (Agent Client Protocol) | rich UI: structured prompts, tool calls, diffs, permission requests | reserved |
| `:native` | in-BEAM process (e.g. Jido agent), no subprocess | rich UI: structured chat | reserved |

Because of `:acp`, the runtime command spec carries `io: :pty | :pipes` — "where it runs" stays orthogonal to "how it talks". `LocalPty` implements `:pty` only; `:pipes` is a small follow-on inside the local runtime, not a redesign.

## Backend design

### `Legend.Agents` (Ash domain)

First real Ash domain, registered in `ash_domains` (this also activates the JSON:API and OpenAPI surface for sessions).

**`Legend.Agents.Session`** (Ash resource, AshSqlite):

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `name` | string | optional, user-supplied |
| `harness_id` | string | registry id, e.g. `"claude_code"` |
| `runtime_id` | string | registry id, e.g. `"local_pty"` |
| `cwd` | string | working directory; defaults to `$HOME` |
| `status` | atom | `:starting \| :running \| :exited \| :failed` |
| `exit_code` | integer | nullable |
| `error` | string | nullable; spawn/launch failure message |
| `started_at`, `ended_at` | utc_datetime | lifecycle timestamps |

Lifecycle actions pair the record with the process: a custom `:start` action creates the record **and** starts the SessionServer (after-commit); `:stop` terminates the process and sets the record to `:exited` (with `exit_code` null when the process was killed rather than exiting on its own); `:destroy` removes both. No path exists where record and process disagree by design.

### `Legend.Agents.SessionServer`

One GenServer per live session under a `DynamicSupervisor` (`Legend.Agents.SessionSupervisor`), located via a `Registry` keyed by session id.

- On start: resolve `harness_id` → harness module → command spec; resolve `runtime_id` → runtime module; start the runtime; update the Ash record to `:running` (or `:failed` with `error`).
- Owns a ring scrollback buffer (~256 KB) for replay on (re)attach.
- Receives `{:runtime_output, data}` → appends buffer → broadcasts on PubSub topic `session:<id>`.
- Handles `write` (stdin) and `resize` casts from the channel.
- On `{:runtime_exit, status}`: updates the record (`:exited`, `exit_code`, `ended_at`), broadcasts the exit event, and **stays alive in `:exited` state** so the final scrollback remains viewable until the session is deleted.
- On terminate: kills the runtime's OS process — crashes cannot leak PTYs.

### `Legend.Harness` (behaviour + registry)

- `definition/0` → `%Legend.Harness.Definition{id, name, description, kind}`.
- Terminal harnesses additionally implement `Legend.Harness.Terminal`: `build_command(opts) :: %CommandSpec{cmd, args, env, io: :pty}` where `opts` carries cwd and env overrides. (`:acp`/`:native` get their own sub-behaviours when built — `build_command/1` is deliberately *not* part of the universal contract.)
- Built-ins: `Legend.Harnesses.ClaudeCode` (default cmd `claude`), `Legend.Harnesses.Hermes` (default cmd `hermes`). Commands are overridable via `.env` (`HARNESS_CLAUDE_CMD`, `HARNESS_HERMES_CMD`) through the existing dotenvy runtime config — nothing machine-specific is hardcoded. Each var holds a full command line (whitespace-split into cmd + args), e.g. `HARNESS_HERMES_CMD="hermes --profile work"`.
- Registry: `config :legend, :harnesses, [Legend.Harnesses.ClaudeCode, Legend.Harnesses.Hermes]`; `Legend.Harness.Registry` lists definitions and fetches by id. Third-party harness plugins later contribute modules to this list.
- Security constraint: `harness_id`/`runtime_id` are user-supplied strings — registries match them by string comparison against definition ids, never `String.to_atom` (atom-exhaustion DoS). `status` uses Ash's enum type with a fixed atom set.

### `Legend.Runtime` (behaviour + registry)

- Callbacks: `start(command_spec, opts) → {:ok, handle} | {:error, reason}`, `write(handle, data)`, `resize(handle, cols, rows)`, `stop(handle)`.
- Output delivery: the runtime sends `{:runtime_output, binary}` and `{:runtime_exit, status}` to the owning SessionServer.
- PoC implementation: `Legend.Runtimes.LocalPty` — spawns the command under a true PTY on the machine the backend runs on (the user's laptop in desktop mode, so local agents work with zero extra infrastructure).
- PTY library (erlexec vs. ExPTY vs. alternatives) is evaluated at plan time. Requirements: a real PTY (Claude Code's TUI needs one), resize, clean kill, and compatibility with the Burrito-packaged sidecar (native artifacts must ship in the release; target is macOS arm only).
- Registry: `config :legend, :runtimes, [Legend.Runtimes.LocalPty]`.

### HTTP & channel surface

- **Session CRUD:** Ash JSON:API at `/api` (list/create/stop/delete via the resource actions).
- **`GET /api/harnesses`:** plain controller in the first router scope (before the AshJsonApi forward) exposing registry definitions for the new-session picker.
- **`SessionChannel`** on the existing `UserSocket`, topic `session:<id>`: join replies with current status + scrollback replay; inbound `input` (text) and `resize` (cols/rows); outbound `output` (base64 — raw terminal bytes are not JSON-safe), `exit`, `status`.
- **`sessions:lobby` channel:** broadcasts "session list changed"; the sidebar refetches. The existing `chat:*` channel remains untouched (future multiplayer rooms).

## Frontend design

Single app shell at `/`:

- **Sidebar:** session list (name, harness badge, status dot), live-updating via `sessions:lobby`; "New session" button.
- **New session dialog** (shadcn): harness picker fed by `GET /api/harnesses`, optional name, working-directory text field defaulting to `$HOME`.
- **Main pane:** the selected session, deep-linkable at `/sessions/[id]`.
- **`Terminal.svelte`:** wraps `@xterm/xterm` + `@xterm/addon-fit`. Keystrokes → channel `input`; channel `output` (base64-decoded) → `term.write()`; container resize → channel `resize`. On mount joins `session:<id>`; the join reply's buffer repaints scrollback.
- **Exited sessions:** frozen scrollback + exit banner (code/error) + delete action.

Identical behavior in browser and Tauri; the desktop sidecar spawns PTYs on the user's machine.

## Error handling & limits

- **Spawn failure** (binary missing, bad cwd): session → `:failed`, error message on the record and in the UI; no zombie process.
- **Channel disconnect ≠ session death:** PTY keeps running; phoenix.js rejoin + buffer replay on reconnect.
- **Backend restart:** a boot pass marks sessions still recorded `:starting`/`:running` as `:failed` ("backend restarted") — no phantom live sessions.
- **SessionServer crash:** supervised; runtime OS process is killed on terminate.
- **Concurrent viewers:** multiple tabs may attach; all receive output and may type (single-user PoC, no arbitration).
- **Bounds:** scrollback ring ~256 KB per session; no session-count cap.

## Testing

- **`TestRuntime`** implements `Legend.Runtime` with scripted output and recorded input — SessionServer and channel tests run without PTYs or API tokens, and it doubles as the second runtime implementation proving the seam.
- Registry/definition unit tests (both harnesses, kind field, `.env` command override).
- SessionServer lifecycle against TestRuntime: start → output → buffer → exit → record updates → stays viewable.
- Channel tests: join replay, input forwarding, resize, exit broadcast, lobby notification.
- One real `LocalPty` integration test spawning `/bin/cat`: echo round-trip, resize, clean exit.
- Ash action tests: `:start` creates record + process; `:stop`/`:destroy` clean up both.
- Frontend: `bun run check` (svelte-check); manual smoke with real `claude` and `hermes` sessions.

## Extension architecture (recorded for later, shapes the PoC contracts)

**ACP harnesses (`:acp`).** The Agent Client Protocol (agentclientprotocol.com) is JSON-RPC over stdio where the client spawns the agent subprocess; types align with MCP. Claude Code has an official adapter (`claude-code-acp`); Gemini CLI speaks it natively. An ACP harness reuses the session/runtime plumbing with `io: :pipes` and gets a rich rendering surface instead of xterm. This is why `kind` and `io` exist in the PoC contracts.

**Native harnesses (`:native`).** A BEAM-resident agent — the planned first one built on Jido (jido 2.x + jido_ai + req_llm) for plain LLM chat without any external CLI. Jido stays out of the PoC: its API is still evolving (early 2.x), and containing it inside a harness plugin isolates that risk from the platform core. `req_llm`'s unified provider interface is also the natural substrate for the future model registry.

**Cloud runtimes.** Docker / Fly Machine / hosted-sandbox modules implementing `Legend.Runtime`; a reverse-tunnel runtime covers agents on remote user machines (CLI connects outbound over WebSocket). The runtime behaviour is transport-shaped (start/write/resize/stop + output events) precisely so these are additive.

**Federated instances (local + cloud).** A user eventually runs more than one Legend instance — the local one (desktop sidecar) and a cloud one — and can open either UI and continue the *same* sessions. The model: each session is owned by the instance that runs its runtime. The local instance pairs with the cloud instance over an outbound WebSocket (reverse tunnel — no inbound ports on the user's machine), registering itself and its live sessions. The cloud UI lists tunneled sessions alongside its own and proxies `session:<id>` channel traffic through the tunnel to the owning instance, where scrollback replay and PTY IO happen exactly as they do locally. The PoC's contracts already accommodate this: session ids are globally unique uuids, channel topics are location-transparent, and on the cloud side a tunnel-backed module implements the same `Legend.Runtime` behaviour. The session schema deliberately gains no instance/node field until federation actually arrives. Federation is also the point where the PoC's "unauthenticated socket on loopback" posture ends: instance pairing and every remotely reachable socket/channel require authentication before any of this ships.

**Agent-to-agent communication.** The substrate is already in the PoC: every session broadcasts on a PubSub topic. The future layer adds rooms — a persistent resource whose members are sessions *and humans* — with a signal envelope (`from_session`, `room`, `content_type`, `payload`) on `room:<id>` topics. The human conductor is a first-class participant, keeping human-in-the-loop structural. Delivery into an agent: native → direct message; ACP → structured prompt request; terminal → harness-formatted PTY text injection. Structured output from an agent, by preference: native (by construction) > ACP (session updates) > Legend-provided MCP tools the agent calls explicitly (`send_message`, `handoff`, `read_messages`) > human relay. Parsing terminal scrollback for messages is explicitly rejected. Remote sessions ride the same WebSocket their runtime already maintains.

**Public plugins.** Registries are config-listed module lists; a packaging/discovery story (hex packages, manifests, runtime loading) layers on once internal plugins have proven the contracts.

## Decisions log

| Decision | Rationale |
|---|---|
| Behaviours + config registries (not pure config, not full plugin system) | Real extension seams at PoC cost; public plugin API designed later against proven contracts |
| Claude Code + Hermes as the two harnesses | Two real implementations force the abstraction to be honest; both are interactive PTY CLIs today |
| Harness `kind` enum + `Terminal` sub-behaviour now | Keeps PTY assumptions out of the universal contract; ACP/native drop in without rework |
| `io: :pty \| :pipes` on the command spec | ACP needs clean pipes; where-it-runs stays orthogonal to how-it-talks |
| No Jido dependency in the PoC | Evolving 2.x API belongs inside a future plugin, not the core |
| ACP out of PoC scope | Terminal layer is needed regardless (universal fallback); ACP's value is a large rich-UI surface — its own project |
| Sessions die with the backend | Honest PoC limitation; marked `:failed` on boot, shown in UI |
| `output` events base64-encoded | Terminal byte streams are not JSON-safe in Phoenix's JSON channel serializer |
| PTY library chosen at plan time | Needs hands-on evaluation against TUI/resize/Burrito requirements |
