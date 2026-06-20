# ACP Rich Sessions — Design

**Date:** 2026-06-20
**Status:** Approved (design)
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`), agent messaging (`2026-06-12-agent-messaging-design.md`), session resume (`2026-06-12-session-resume-design.md`), the Sprites cloud-runtime + tunnel specs (2026-06-13/14/15)

## What this is

Today every session is a `:terminal` harness: a CLI under a PTY, rendered as raw bytes in xterm. This spec adds **`:acp` sessions** — the [Agent Client Protocol](https://agentclientprotocol.com) (JSON-RPC 2.0 over stdio, client spawns the agent subprocess) — so a session that runs an ACP-capable agent gets a **rich structured UI** (streaming messages + reasoning, tool calls with diffs, interactive permission prompts, plans, slash commands) instead of a terminal.

The same Claude Code conversation can be driven through **either** transport and **switched live**, because Legend's session id already *is* the agent's conversation id and Claude Code's terminal CLI and its ACP adapter share one on-disk conversation store. The design also covers running ACP agents on **cloud/remote runtimes** and adding **Codex** (and Gemini) as further ACP harnesses.

This realizes the `:acp` extension point reserved in the PoC (`kind` + `CommandSpec.io: :pty | :pipes`).

## Vision context

Legend is an orchestrator for AI agents — a unified interface across harnesses. The terminal layer made *any* CLI usable; ACP makes *capable* agents first-class with a native UI. It is the large rich-UI surface the PoC deliberately deferred as "its own project." Per `VISION.md`, the rich UI is also where "UI panels are extension points" starts paying off: the ACP conversation is a new surface in the tiling workspace, peer to terminals and files.

## Goals

1. Run an ACP agent as a session and render its full structured stream in a rich, native UI.
2. **One Claude Code harness, two transports** (`:acp` default, `:terminal` fallback), **switchable live** within a single session/conversation.
3. Generalize the session spine so the content model (byte scrollback vs structured timeline) is polymorphic, not special-cased — the clean version of the PoC's `kind`/`io` seams.
4. Shape the design so **cloud/remote** ACP and **additional ACP agents (Codex, Gemini)** are additive, not redesigns.

## Non-goals (Phase 1)

- Cloud/remote ACP (designed here; built in Phase 2).
- Codex / Gemini harnesses (designed here; built in Phase 3).
- Client-side `fs/*` and `terminal/*` ACP capabilities — Phase 1 does **not** advertise them; the agent uses its own native file/terminal tools and we render the resulting `tool_call` updates (diffs included).
- Persisting the conversation transcript in Legend's DB — the agent owns the durable record (its JSONL); Legend keeps only an in-memory live cache. (A Legend-side durable/queryable transcript store is a possible later feature, addable without rework.)
- Auth/multi-user changes; the loopback single-user posture is unchanged.

## Key decisions (locked)

| Decision | Choice |
|---|---|
| Phase 1 scope | Depth-first: full rich UI for **Claude Code on the local runtime**; cloud + Codex designed-for, phased |
| Transport model | **One harness, switchable transport.** Drop `Definition.kind`; add `Definition.transports :: [:terminal \| :acp \| :native]` (ordered, first = default). Add `session.transport`. |
| Live switching | Suspend → relaunch into the **same `conversation_id`** under the other transport. Mid-turn loss is acceptable (same as suspend/resume today). |
| Conversation identity | New `session.conversation_id`: pinned to Legend's id when we can (terminal `--session-id`), captured from the agent when we can't (ACP `session/new`). All resume/switch key off it. |
| Timeline storage | **In-memory live cache**; the agent's JSONL is the durable record; repaint on resume via ACP `session/load`. No Legend DB transcript. |
| Protocol layer | **Generalize `SessionServer`**; extract `Legend.Core.Acp.Connection` (in-process JSON-RPC codec, no ACP library — matches the hand-rolled-MCP decision). |
| Compatibility | Early-stage: prefer a clean refactor over back-compat shims. Replace `kind` outright and migrate all readers. |

## Architecture

### Harness contract: a second sub-behaviour

`Definition.kind` is replaced by `transports` (the set the harness can speak; first entry is the default):

```elixir
# Legend.Core.Harness.Definition
defstruct [:id, :name, description: "", resumable: false, transports: [:terminal]]
# ClaudeCode → transports: [:acp, :terminal]; Hermes → [:terminal]
```

Every reader migrates from `kind` to `transports` / `session.transport`: the registry, `GET /api/harnesses`, and the frontend's "kind → UI" becomes "**`session.transport` → UI**."

A new sub-behaviour parallels `Legend.Core.Harness.Terminal`:

```elixir
defmodule Legend.Core.Harness.Acp do
  @moduledoc """
  Contract for harnesses that can be driven over ACP. The harness only says how
  to SPAWN its adapter subprocess; the ACP wiring (cwd, mcpServers, instructions,
  load-vs-new) is standard protocol driven generically by the SessionServer, not
  per-harness.
  """
  @callback acp_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()  # io: :pipes
end
```

`Legend.Harnesses.ClaudeCode` implements **both** behaviours: `build_command/1` → `claude …` (`io: :pty`), `acp_command/1` → `claude-code-acp` (`io: :pipes`, env passthrough). The ACP harness is deliberately thin — `library`/`mcp`/`messaging`/`mode` no longer become CLI args; they flow into the ACP handshake, assembled generically by the SessionServer.

### Session record: two new fields

| Field | Type | Notes |
|---|---|---|
| `transport` | `:terminal \| :acp` | the active transport; defaults to the harness's first `transports` entry; flippable via `set_transport` |
| `conversation_id` | string | durable agent-conversation handle; decouples Legend's `id` from the agent's conversation id |

`conversation_id` is set to Legend's `id` when we can pin it (terminal `--session-id <id>`) and **captured** from the agent when we can't (ACP `session/new` returns one). Resume and transport-switch both key off `conversation_id`: terminal `--resume <conversation_id>`, ACP `session/load <conversation_id>`. This handles an adapter that insists on minting its own id, and is more robust than the current implicit "Legend id == conversation id" coupling.

### `Legend.Core.Agents.Transcript` — polymorphic content model

A protocol with two implementations, so `SessionServer` never special-cases the content model:

| | terminal | acp |
|---|---|---|
| impl | `ByteScrollback` (bounded byte ring) | `AcpTimeline` (ordered event list) |
| cursor | byte offset | monotonic event `seq` |
| `append/2` | append bytes | append normalized event(s) |
| `snapshot/1` | `{bytes, byte_offset}` | `{events, seq}` |

The loss/duplication-free reattach invariant (subscribe to PubSub *before* snapshotting, drop live items below the cursor) is unchanged — just generalized from a byte offset to a `seq` cursor. Only the **channel encoding** differs at the edge (base64 bytes vs JSON events).

### `Legend.Core.Acp.Connection` — the protocol codec (not a process)

A module + state struct held **inside** the `SessionServer` (one spine; no ACP library):

- `init/1` → the launch frames to send: `initialize` (clientCapabilities: **no** `fs`/`terminal` in Phase 1) then `session/new {cwd, mcpServers}` *or* `session/load {sessionId, cwd, mcpServers}`.
- `handle_bytes(buffer <> new_bytes, state) :: {events, replies, new_state}` — buffers partial lines, parses newline-delimited JSON-RPC, and produces:
  - **`session/update` notifications** → normalized **timeline events** (a stable internal struct the frontend renders): `agent_message_chunk`, `agent_thought_chunk`, `tool_call` / `tool_call_update` (incl. diff content), `plan`, `available_commands_update`, `current_mode_update`.
  - **agent→client requests** — `session/request_permission` → a `permission_request` event carrying the JSON-RPC `id`, recorded **pending**; reply deferred until the human answers (§ Permission round-trip). `fs/*` and `terminal/*` are not advertised, so not received.
  - **responses to our requests** (`session/new`, `session/load`, `session/prompt`) → correlated by id; a `session/prompt`'s late `stopReason` becomes a `turn_complete` event.
- `prompt/2`, `cancel/1`, `set_mode/2`, `answer_permission/3` → encode outbound frames the SessionServer writes via `runtime.write`.

### `SessionServer` generalization

The server holds one `transcript` (polymorphic) and a `transport`, and dispatches:

- inbound: terminal → `write`(bytes)/`resize`; acp → `prompt`/`cancel`/`set_mode`/`answer_permission` (resize ignored — no PTY).
- `{:runtime_output, bytes}`: terminal → append to `ByteScrollback`, broadcast `{:session_output, offset, bytes}`; acp → feed `Acp.Connection.handle_bytes`, append emitted events to `AcpTimeline`, broadcast `{:session_event, seq, event}`, write any replies.
- tunnel / nudge / spawn-policy / exit / janitor logic is **shared verbatim** across transports.

**Messaging delivery (signal bus → agent).** For ACP, the inbound-message nudge is no longer a PTY line — it becomes a structured timeline event the UI surfaces (and, optionally later, an injected user turn). The inbox/pull semantics (`read_messages`) are unchanged; only the delivery adapter varies by transport, exactly as the messaging spec anticipated.

### Permission round-trip (centerpiece of the rich UI)

`session/request_permission` is a JSON-RPC **request** that must round-trip through the human:

1. Agent → `request_permission` → `Acp.Connection` emits a `permission_request` event (with request id + options) and records it pending.
2. `SessionServer` appends it to the timeline (so a reattaching client sees still-open prompts) and broadcasts it.
3. Human picks an option → channel `permission {requestId, optionId}` → `SessionServer` → `Acp.Connection.answer_permission` → JSON-RPC response to the agent → pending entry resolves (a resolution event updates the timeline).

Unanswered prompts are part of the replayable snapshot — refresh / second tab / restart-then-resume all see the open request.

### Runtime seam: a `:pipes` path

The `Runtime` contract is unchanged. `LocalPty` gains a `:pipes` mode (erlexec without `:pty`: stdin pipe + stdout to owner), delivering the same `{:runtime_output, bytes}` / `write/2` contract. Cloud (`Sprites`) gets the same `:pipes` exec in Phase 2. Because `Acp.Connection` runs backend-side regardless of where the process executes, **ACP is location-transparent over the runtime seam**.

### Channel surface

`session:<id>` join reply gains `transport`. For `:acp`: `{transport: "acp", snapshot: [events…], cursor: seq, open_permissions: […]}` (JSON, not base64). Inbound: `prompt {content}`, `cancel`, `permission {requestId, optionId}`, `set_mode {modeId}`, `stop` (suspend). Outbound: `event {seq, event}`, `exit`, `status`. Terminal frames are unchanged (base64 bytes). `set_transport` is a REST/Ash action, not a channel message.

## Resume & transport switching

`SessionServer` launch branches on `(transport, mode)`:

| transport | fresh | resume |
|---|---|---|
| **terminal** | `claude --session-id <conversation_id>` + primers (`--append-system-prompt`) + MCP (`--mcp-config`) + instructions positional | `claude --resume <conversation_id>` (no instructions) |
| **acp** | spawn `claude-code-acp` (`:pipes`) → `initialize` → `session/new {cwd, mcpServers}` → capture/pin `conversation_id` → instructions as first `session/prompt` | spawn → `initialize` → `session/load {conversation_id, cwd, mcpServers}` → adapter replays history → rebuild `AcpTimeline` + repaint (no instructions) |

**Transport switch** is a `set_transport` action: persist `session.transport`; if live, stop the current process and relaunch via the *resume* path under the new transport keyed on the shared `conversation_id`. Terminal→ACP `session/load`s the JSONL the TUI wrote; ACP→terminal `--resume`s the uuid the adapter captured (the `~/.claude/projects/<encoded-cwd>/session-<uuid>.jsonl` store is shared between the TUI and the adapter). **Resume and switch are the same relaunch code**, differing only in whether `transport` changed.

**Capability gating.** The toggle shows only when `transports` has >1 entry. ACP resume attempts `session/load` only if the agent advertised the `loadSession` capability at `initialize` (discovered at runtime — authoritative), else degrades to a fresh ACP session (mirroring how non-`resumable` terminal harnesses degrade today). Use `session/load` specifically (it replays history to the client); a bare resume restores only internal SDK state without replay.

## Frontend: the rich surface

A new surface `AcpConversation` (registered in `surfaces.ts`) renders the timeline; `SessionPane` selects it vs `Terminal` by `session.transport`. The **tile shell is shared** — header (status dot, name, harness tag, summary, focus/details/close), drag-to-tile, in-tile Details — only the body swaps. Built on Legend tokens + shell primitives (no raw shadcn/hex).

Converged design (validated via mockups `acp-surface*.html`):

- **Seamless single-agent thread, no avatars.** User turns are a soft right-aligned bubble; the agent's replies are plain prose (no repeated name). Tool calls, reasoning, and permission cards run full-width inline.
- **Messages** render markdown + code blocks; **reasoning** (`agent_thought_chunk`) is a collapsible "Thought…" strip (collapsed by default).
- **Tool calls** are cards: a `kind` label (read/edit/execute/…), a status (✓ / spinner / ✗), inline **diffs** (`tool_call_update` diff content), and streaming command output.
- **Plan** is a **sticky bar pinned above the composer** (lifted out of the scroll): a one-line summary (`1 / 3` + current step) that expands to the full checklist; the Details panel mirrors the full plan for wide tiles.
- **Queued messages** sit (sticky) just below the plan: prompts fired while the agent is mid-turn land here as numbered, reorderable, removable, **editable** rows, each with **▶ send-now** (jump the queue). Legend holds them and flushes via `session/prompt` on `turn_complete` (ACP runs one turn at a time, so the queue is a Legend-side feature). The composer's send button flips to **`＋ Queue`** while the agent is busy.
- **Composer** is one unit: textarea on top; a context row below with **`＠ Add context`** plus **file/@-mention chips** and **image chips** (→ ACP `resource_link`/`resource` content blocks appended to the prompt), the **mode selector** (`session/set_mode`), and Stop (`session/cancel`) / Send. A subtle **context-info footer** shows cwd, model, and a context-window usage meter; slash commands come from `available_commands_update`.
- **Transport toggle** (`rich ⇄ term`) in the header, shown only when the harness speaks both.

## Cloud/remote (Phase 2 — additive)

`Acp.Connection` runs backend-side on loopback regardless of where the agent runs, so cloud ACP needs exactly one new thing:

- **`Sprites` gains a `:pipes` exec mode** (stdin/stdout over the existing WSS exec carrier, no PTY) — same contract as `LocalPty :pipes`.

Everything else already exists and is transport-agnostic:

- **MCP signal bus + library** flow through **`session/new mcpServers`** (ACP supports HTTP MCP servers with headers): local → loopback `/api/mcp`; cloud → the tunnel `base_url <> "/api/mcp"` + bearer token — the same `base_url` rewrite already done for terminal. `library: :api` keeps the `library_*` MCP tools; `:path` keeps `LEGEND_LIBRARY`.
- **Cloud resume = relaunch the adapter in the sprite + `session/load`** (sprite FS persists the conversation across hibernation), so ACP does not need the PTY "reattach-to-live" path — `session/load` is its true-survival analog.

## Codex + Gemini (Phase 3 — thin)

With the spine + rich UI in place, each new ACP agent is a **harness module + provisioning + auth surface**; the protocol engine, timeline, UI, channel, and `:pipes` runtime are shared and agent-agnostic:

- **`Legend.Harnesses.Codex`**: `transports: [:acp]`; `acp_command/1` → `npx @zed-industries/codex-acp` (or a configured `codex-acp` binary); `OPENAI_API_KEY`/`CODEX_API_KEY` from settings; `provision/0` detects/installs the adapter; **supports `session/load`** so resume + switch work. API-key entry is surfaced through the existing **harness setup seam** (`/settings` card + new-session notice).
- **Gemini**: native ACP (`transports: [:acp]`) — nearly free once the spine exists.

The "second agent ≈ a thin module" payoff is the reason the protocol logic lives in the shared layer.

## Error handling

- Adapter missing → `:failed` (+ `provision` install flow); `initialize`/protocol-version failure → `:failed` with the error, surfaced in the UI.
- **Malformed JSON-RPC frame → log + skip, never crash the session**; a hard desync surfaces a soft error event in the timeline.
- Agent exits mid-session → `:exited`, timeline frozen, resume offered; any pending permission request marked cancelled.
- `session/prompt` error `stopReason` (refusal, max_tokens) → a `turn_complete` event with the reason — not a session failure.
- `session/cancel` is best-effort; Stop also offers a hard suspend (kill the process).
- Backend restart → janitor marks ACP sessions `:interrupted` (unchanged); resume relaunches + `session/load`.
- Queue is in-memory (lost on restart, like the timeline — acceptable Phase 1).

## Testing

- **A scripted `Test` ACP agent** (speaks the protocol over pipes: `initialize`, `session/new`, scripted `session/update`s, a `request_permission`, prompt handling) — the linchpin, mirroring `TestRuntime`: the whole ACP path tests with no real adapter or tokens, and it is a real second protocol implementation that proves the seam.
- `Acp.Connection` units: framing across chunk boundaries, request/response correlation, `session/update` → event normalization, permission round-trip, error frames.
- `Transcript` units: both impls satisfy `append`/`snapshot`/cursor; reattach replay invariant for byte *and* event cursors.
- `SessionServer` ACP lifecycle (fresh handshake → prompt → events → permission round-trip → `turn_complete` → exit → frozen → resume/`session/load` repaint) and transport-switch (Test runtime + Test ACP agent).
- Channel: join reply (transport, snapshot, open permissions), inbound `prompt`/`cancel`/`permission`/`set_mode`, outbound `event`/`exit`/`status`.
- Frontend: `AcpConversation` rendering per event type, composer queue logic, `bun run check`.
- Optional gated integration test against a real `claude-code-acp`.

## Phasing / decomposition

Each phase is an independently shippable plan → build → review cycle.

- **Phase 1 (build now):** spine + local + Claude Code + full rich UI — `transports` + `Acp` behaviour; `transport`/`conversation_id`; `Transcript` refactor + `AcpTimeline`; `Acp.Connection`; `SessionServer` generalization; `LocalPty :pipes`; channel ACP events; `ClaudeCode.acp_command/1`; Test ACP agent; the rich Svelte surface.
- **Phase 2:** cloud — `Sprites :pipes`, MCP via `session/new`, cloud resume via `session/load`.
- **Phase 3:** Codex + Gemini harnesses (definitions, provisioning, auth surface).

## Verify-at-plan-time (open unknowns)

1. Whether `claude-code-acp` lets us pin `conversation_id` at `session/new` (else capture the adapter's id).
2. Primer delivery in ACP (adapter system-prompt env var vs folding the library/messaging primer into the first prompt).
3. Exact ACP protocol version to pin (≥ 0.11) and precise `session/update` field shapes — we hand-roll, so we lock to the version we test against.
4. `claude-code-acp` invocation specifics (npx vs installed binary; required env / auth passthrough).
5. Sprite-FS persistence of the adapter's conversation store across hibernation (so cloud `session/load` works).

On implementation, update `docs/ARCHITECTURE.md` (the ACP entries move from "reserved" to "built (Phase 1)", new `Acp` seam + `Transcript` abstraction recorded) and keep the spec index in sync.

## Decisions log

| Decision | Rationale |
|---|---|
| Depth-first Claude Code, local, full rich UI | Proves the hardest parts (protocol engine + rich renderer) once, end-to-end, before fanning out to cloud/agents |
| One harness, switchable transport (drop `kind` for `transports`) | A single conversation rendered two ways; live switch is feasible because Legend's id is the conversation id and the TUI + ACP adapter share one store; cleaner than two harness ids or a `kind`/`transport` split |
| `conversation_id` separate from Legend `id` | Decouples Legend's id from the agent's conversation handle; handles adapter-minted ids; robust resume/switch key |
| In-memory timeline + `session/load` | The agent's JSONL is already the durable record; no Legend DB transcript needed; consistent with the suspend/resume model |
| Generalize `SessionServer` + in-process `Acp.Connection` | One spine, trivial transport switching; hand-rolled JSON-RPC matches the hand-rolled-MCP decision (tiny surface, no library) |
| No client-side `fs`/`terminal` in Phase 1 | Agent's native tools suffice and diffs still render via `tool_call` updates; client-side capabilities are a later refinement |
| MCP via `session/new mcpServers` for ACP | ACP's native mechanism; reuses the existing tunnel `base_url` rewrite unchanged for cloud |
| Queue as a Legend-side feature | ACP runs one turn at a time; queue + send-now is genuinely useful and lives entirely client/server-side |
| Clean-over-compat refactor | Early-stage; no external consumers; carrying `kind` for compatibility costs more than migrating callers |

## References

- ACP: https://agentclientprotocol.com — JSON-RPC 2.0 over stdio; lifecycle `initialize` → `session/new`/`session/load` → `session/prompt`/`session/cancel`/`session/set_mode`; `session/update` notifications; client methods `session/request_permission`, `fs/*`, `terminal/*`.
- `claude-code-acp` (`@zed-industries/claude-code-acp`) — Claude Code ACP adapter; supports `session/load` (replays JSONL history); shared `~/.claude/projects/<encoded-cwd>/session-<uuid>.jsonl` store.
- `codex-acp` (`@zed-industries/codex-acp`) — Codex ACP adapter; `OPENAI_API_KEY`/`CODEX_API_KEY`/ChatGPT auth; supports `session/load`.
- Mockups: `.superpowers/brainstorm/<session>/content/acp-surface*.html` (rich surface iterations).
