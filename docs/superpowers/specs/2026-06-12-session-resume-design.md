# Session Resume on Restart — Design

**Date:** 2026-06-12
**Status:** Approved
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`), agent messaging (`2026-06-12-agent-messaging-design.md`)

## Problem

Local-PTY agents are child processes of the backend: an app/backend restart kills them, and the boot janitor marks their sessions `failed / backend restarted`. The PoC accepted this; in practice losing every session on restart is the single most painful UX gap.

## Decision: suspend/resume, not true survival

Two models were considered:

1. **True survival (detacher):** run agents inside a PTY-holding process that outlives the backend (tmux session, or a bundled dtach/abduco), reattach on boot. The agent keeps *working* during the outage. Cost: an external/bundled detacher dependency, reattach machinery, self-persisted scrollback (the in-memory ring dies with the BEAM regardless).
2. **Suspend/resume (chosen):** the process dies with the backend; on demand we relaunch a *fresh* process into the *same conversation* using the agent's own persistence — Claude Code's `--session-id <uuid>` (set the conversation id at launch) and `--resume <uuid>` (relaunch into it).

Suspend/resume is dramatically less machinery (no detacher, no packaging change, no scrollback persistence layer) and converges with where the architecture goes anyway: it is exactly the semantics ACP harnesses will have via `session/load`, behind the same boot-time question — *"can this session come back?"* — answered per harness. True survival remains a clean future upgrade for `:terminal` sessions (see Future).

**Accepted tradeoffs (recorded honestly):** in-flight work dies at restart — the *conversation* resumes, not the interrupted turn; pre-restart terminal scrollback is gone — the agent's own conversation redraw stands in for it.

## Goals

1. After a backend/app restart, a previously running session is shown as **interrupted** (not failed) and can be brought back with one click, continuing its conversation (where the harness supports it).
2. Messages that arrived while the session was down are delivered (nudged) after resume — the signal bus already buffered them.
3. The human decides: **manual resume only**, no auto-respawn on boot (no surprise PTY spawns or token spend).

## Non-goals

- True survival / detached agents (future upgrade, recorded below).
- Resuming across machine reboots beyond what the harness's own persistence provides.
- Auto-resume on boot.
- Scrollback persistence to disk.

## Design

### Lifecycle

- New session status: **`:interrupted`** (enum gains it; frontend `SessionStatus` too).
- The boot janitor marks orphaned `:starting`/`:running` sessions `:interrupted` instead of `:failed` ("backend restarted" disappears for this case). Real spawn/launch failures keep `:failed`.
- New **`:resume`** update action on `Legend.Core.Agents.Session`, allowed from `:interrupted` **and `:exited`** (same machinery; "continue yesterday's conversation" comes free). It clears `exit_code`/`error`/`ended_at`, sets `:starting`, and restarts a SessionServer for the same record in an `after_transaction` hook — the same record/process-lockstep pattern as `:start`. Same env injection, same `mcp_token`, lineage and message history intact.
- Exposed on the JSON:API as a member route (exact AshJsonApi route form chosen at plan time; plain-controller fallback in the first router scope if it fights us).

### Terminal contract: `mode`

`Legend.Core.Harness.Terminal.build_command/1` opts gain `mode: :fresh | :resume`:

- **ClaudeCode:** `:fresh` → `--session-id <legend-session-id>` (our session id *is* the agent's conversation id); `:resume` → `--resume <legend-session-id>`. In `:resume` mode the `instructions` positional prompt is **omitted** (the conversation already contains it); primers and MCP flags stay (per-invocation).
- **Hermes:** ignores `mode` (no known resume mechanism) — resume degrades to a fresh process in the same cwd.
- `Legend.Core.Harness.Definition` gains **`resumable: boolean`** so the UI labels the affordance honestly: **Resume** vs **Restart**.
- Plan-time verification (PTY-library precedent): `--resume` composing with `--append-system-prompt`/`--mcp-config`; `--session-id` accepting our UUID at first launch.

### Catch-up nudge

On any successful SessionServer start (fresh or resume), check the session's unread message count; if > 0, arm one debounced nudge. Without this, messages that arrived while the session was down would sit unread forever — nudges otherwise fire only on new broadcasts. (Also covers the fresh-start edge of messages sent to a `:starting` session.)

### Frontend

- `SessionStatus` gains `'interrupted'`; sidebar dot gets a distinct color.
- Session page: "interrupted — backend restarted" state with a **Resume** button (label **Restart** when the harness isn't `resumable`); `:exited` sessions gain the same button next to Delete.
- Resume re-joins `session:<id>` like any running session; scrollback starts fresh (agent redraws its conversation).

## Error handling

- Resume of a deleted/unknown session → standard JSON:API 404.
- Resume spawn failure (binary missing, bad cwd) → `:failed` with error, exactly like `:start`.
- Resume while already running → action rejected by status filter (only `:interrupted`/`:exited` accepted).
- `max_running_sessions` cap applies to resumes the same as `start_agent` spawns? **No** — the cap guards runaway *agent-initiated* delegation; a human clicking Resume is the conductor acting. Recorded as deliberate.

## Testing

- Janitor marks orphans `:interrupted` (not `:failed`).
- `:resume` action: from `:interrupted` and `:exited` restarts process + record (TestRuntime); rejected from `:running`; spawn failure → `:failed`.
- ClaudeCode `build_command` mode mapping: `--session-id` on fresh, `--resume` + omitted instructions on resume; Hermes degradation (no mode flags).
- Catch-up nudge: unread > 0 at start → one nudge (TestRuntime); zero unread → none.
- Channel/API: resume route round-trip; status `interrupted` serialized.
- Frontend: `bun run check`. Manual acceptance: create session → converse → restart backend → status interrupted → Resume → conversation continues → message sent during downtime nudges.

## Future: fully detached sessions (true survival)

The upgrade path if "agent keeps working while the backend is down" becomes worth its cost: run `:terminal` agents inside a detacher that owns the PTY and outlives the backend — tmux (`legend-<id>` sessions; scrollback via `capture-pane`) for dev, or a bundled tiny detacher (dtach/abduco) for the self-contained desktop, with scrollback self-persisted to disk so detachers stay interchangeable. The boot pass then asks the same question this design introduces ("can this session come back?") and *reattaches* instead of marking interrupted. ACP harnesses answer the same question with `session/load`; a pipe-holding relay would be their true-survival analog. Nothing in this design is throwaway under that upgrade — `:interrupted` + `:resume` remain the fallback when the detacher's session is gone.

## Decisions log

| Decision | Rationale |
|---|---|
| Suspend/resume over detacher | Far less machinery; covers the actual complaint (app restart); same semantics ACP gets via `session/load`; detacher stays a compatible upgrade |
| Manual resume only | Human is the conductor; no surprise spawns/token spend on boot |
| Our session id = Claude Code conversation id (`--session-id`) | No mapping table; `--resume <id>` needs nothing stored beyond what exists |
| Resume allowed from `:exited` too | Same machinery, real value (continue finished conversations) |
| Instructions omitted in `:resume` mode | The conversation already contains them; re-sending duplicates |
| `resumable` on Definition | UI can label Resume vs Restart honestly per harness |
| Catch-up nudge on (re)start | The bus buffers across downtime; without a knock the agent never drains it |
| Session cap not applied to manual resume | Cap bounds agent-initiated fan-out, not conductor actions |
