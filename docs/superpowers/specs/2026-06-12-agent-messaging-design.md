# Agent Messaging & Delegation — Design

**Date:** 2026-06-12
**Status:** Approved
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`), shared library (`2026-06-11-shared-library-design.md`)

## Vision context

VISION.md names handoff fluidity and agent-to-agent communication as orchestration core. This spec is the first slice of that story: agents message each other, delegate work by spawning sessions, hand off with context, and report back — with the human watching and able to join every exchange.

**Deliberately smaller than the vision's "rooms":** sequential handoff and delegation need no shared-membership construct. Every message here has exactly one recipient; the human sees everything (single local user). Rooms arrive later as a grouping/membership layer for group chat — the envelope gains a `room_id` then; nothing built here is thrown away.

**The acceptance demo:** in a session, tell Claude Code "use `start_agent` to launch Hermes, ask it to summarize X, and report back what it says." Spawn → primer → work → `send_message` → nudge → relay, all visible in the timeline.

## Goals

1. Agents in sessions can message each other, list each other, spawn new agent sessions with instructions, and hand off — via Legend-provided MCP tools.
2. The human watches all agent-to-agent traffic live and can message any session, through the same bus (no special human path).
3. Contracts shaped so `:acp` and `:native` harnesses drop into the same inbox semantics later with only their delivery adapter differing.

## Non-goals (recorded as direction, not built)

- Rooms: shared timelines, membership, group addressing, baton enforcement.
- The native (Jido) conductor agent — its own follow-up project; this slice proves the loop terminal-only.
- ACP/native delivery adapters (the seam is defined; only `:terminal` is implemented).
- Multi-user/auth (single local user; existing loopback posture).
- Task entities / conductor-dispatch semantics (decomposition, assignment, collection).
- Delivery confirmation. Scrollback parsing stays rejected; if an agent ignores a nudge, the unread badge shows and the human conducts.

## Architecture

```
agent CLI ──MCP (HTTP + per-session token)──► /api/mcp ──► Signals domain (Ash)
                                                              │ Message created
                                              PubSub ◄────────┘
                                  ┌───────────┴───────────────┐
                          inbox:<session_id>             signals (global)
                                  │                           │
                          SessionServer                signals:timeline channel
                         (nudge into PTY)               (live UI timeline)
```

The bus never depends on the recipient being ready: messages persist first, broadcast second. Busy, crashed, exited, or not-yet-spawned recipients catch up on their next `read_messages`.

### `Legend.Core.Signals` (new Ash domain)

Registered in `ash_domains` (JSON:API surface comes free). One resource:

**`Message`**

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `from_session_id` | uuid, nullable | `nil` = the human |
| `to_session_id` | uuid | exactly one recipient |
| `kind` | atom | `:message \| :handoff \| :system` |
| `payload` | text | cap ~64 KB |
| `read_at` | utc_datetime, nullable | inbox = `read_at IS NULL` |
| `inserted_at` | utc_datetime | timeline order |

No cursor arithmetic: single-recipient messages make the inbox a `read_at IS NULL` filter, and `read_messages` a mark-read. Creation broadcasts on `inbox:<to_session_id>` (nudge trigger) and the global `signals` topic (UI), from the Ash action's notifier — one write path shared by MCP, JSON:API, and system events.

**`Session` gains `spawned_by_session_id`** (nullable uuid): set by `start_agent`/spawn-handoff, giving the UI its delegation tree (walk to root = one orchestration thread).

### MCP server (`POST /api/mcp`)

- Streamable-HTTP MCP endpoint in the **first router scope** (before the AshJsonApi forward — router order is load-bearing).
- **Per-session identity:** `SessionServer` generates a token at start and injects `LEGEND_MCP_URL` + `LEGEND_SESSION_TOKEN` into the agent's env (the `LEGEND_LIBRARY` pattern). The token maps each MCP call to its session — `send_message` knows who "I" am without trusting the agent's claim. Bad/missing token → 401.
- **Library choice at plan time** (hermes_mcp/anubis_mcp/ex_mcp vs. a hand-rolled minimal JSON-RPC handler — the needed surface is small). Same precedent as the PTY library decision.

### The five tools

| Tool | Behavior |
|---|---|
| `send_message(to, content)` | Create `Message` to a session id (or `"requester"` for the spawner) |
| `read_messages()` | Return unread inbox, mark read |
| `start_agent(harness, instructions, name?, cwd?)` | Spawn a session (existing `:start` Ash action — no second lifecycle path) with `spawned_by` = caller; instructions + messaging primer delivered at launch; returns new session id. `cwd` defaults to the spawner's |
| `handoff(to, summary)` | `kind: :handoff` message; `to` may be a session id **or** a harness id (spawn + launch-context). Advisory — no enforcement |
| `list_agents()` | Sessions with id, name, harness, status — the "how is Claude Code doing" substrate |

When a session with a spawner exits, its `SessionServer` posts a `kind: :system` message to the spawner's inbox ("session exited, code 0") — "report back when done" survives a forgetful agent.

### Harness wiring (Terminal contract extensions)

- `build_command/1` opts gain `mcp: %{url, token}`. **Claude Code:** `--mcp-config` inline JSON (token in header) + `--allowedTools` for the `legend__*` tools. **Hermes:** its MCP registration mechanism, confirmed at plan time. A harness that can't speak MCP still runs — it just can't message (terminal-fallback principle).
- **Launch delivery** for spawned sessions, via the same mechanism as the library primer (never raw PTY injection): (1) the messaging primer — "you are session `<id>`, started by `<spawner>`; you have these tools; report progress and results via `send_message`" — and (2) the caller's `instructions` as the initial prompt (per-harness detail; positional arg for Claude Code).

### The runtime nudge (`:terminal` delivery adapter)

When a message lands in a running session's inbox, its `SessionServer` injects one line into the PTY and submits it:

```
[legend] 2 unread message(s) from hermes-research — call read_messages to view
```

- **Debounced ~2s:** a burst produces one nudge with a count.
- Mid-generation, the line queues in the TUI input box and submits next turn — acceptable; content is safe in the inbox regardless.
- Format is a default on the `Terminal` contract, overridable per harness.
- No nudge after exit; messages to exited sessions accumulate as unread (visible in UI, harmless).
- Future kinds swap only this adapter: `:acp` pushes a structured prompt (nudge + content collapse into one step), `:native` receives a BEAM message. Inbox semantics are unchanged.

## Frontend design

- **`/messages` (global timeline):** live feed of every envelope (messages, handoffs, spawns, exits), grouped by delegation chain (root of `spawned_by`). Live over a new `signals:timeline` channel pushing each envelope (join replays a recent window). Composer: pick any running session, send as human (`from: nil`) — same path as agent messages, nudge included.
- **Per-session panel** on `/sessions/[id]`: collapsible inbox/outbox beside the terminal with a pre-targeted composer. Renders the same `Message` data — a filter of the timeline, not a second system.
- **Sidebar:** unread-count badge per session.

## Error handling & limits

- Payload > ~64 KB → MCP error directing the agent to put the artifact in the shared library and send the path (messages carry references; the library carries bulk).
- Unknown target session / harness id → structured MCP errors. Registry ids matched by string comparison, never `String.to_atom`.
- **Runaway delegation:** `start_agent` enforces a global cap on concurrently running sessions (configurable, default 10) with a clear error. Beyond that, accepted PoC risk — the timeline shows everything and the human can stop any session.
- Backend restart: messages and unread state persist (SQLite); sessions die as today; the timeline survives as the audit trail.

## Testing

- Tool handlers against fixtures: send/read marks unread correctly; `start_agent` sets `spawned_by` and respects the cap; handoff-to-harness spawns; unknown ids error.
- `SessionServer` nudge via `TestRuntime`: inbox broadcast → nudge bytes; debounce coalesces; no nudge after exit; exit → `:system` message to spawner.
- MCP endpoint: JSON-RPC round-trip with token auth; 401 without.
- Channel test: timeline replay on join + live push. Frontend: `bun run check`.
- Manual acceptance: the demo above with real `claude` + `hermes`.

## Decisions log

| Decision | Rationale |
|---|---|
| No Room resource in this slice | Pairwise delegation/handoff doesn't need membership; single local user sees everything; envelope gains `room_id` when group chat arrives |
| Inbox = unread rows, not cursors | Single-recipient messages make `read_at IS NULL` the whole inbox model |
| Notify + pull (nudge → `read_messages`) | Message bodies never transit the TUI; one predictable injected line; generalizes to ACP/native where the adapter swaps |
| MCP over streamable HTTP on Phoenix | No extra processes; works unchanged for future cloud runtimes; per-session token reuses the env-injection pattern |
| `start_agent` (delegate) distinct from `handoff` (baton) | The conductor scenario is delegation — spawner stays engaged; handoff is advisory step-back. Different verbs, same bus |
| Exit posts a `:system` message to the spawner | "Report back when done" must survive a forgetful agent |
| Human is `from: nil` on the same bus | Human-as-conductor structural, not a special code path |
| Scrollback parsing / delivery confirmation rejected | Unread state + human conduction cover it; parsing TUIs is a dead end |
| MCP library chosen at plan time | Needs hands-on evaluation; hand-rolling the small JSON-RPC surface is a live option |
