# ACP session resume continuity (`session/resume`)

**Date:** 2026-06-22
**Status:** Design — approved, pending implementation plan
**Related:** [2026-06-20-acp-rich-sessions-design.md](2026-06-20-acp-rich-sessions-design.md) (§"Resume & transport switching", §"Capability gating")

## Context

When a Claude Code session is resumed, restarted, or switched terminal→rich, the ACP launch runs in `mode: :load` (driven purely by the presence of a persisted `conversation_id`, in `SessionServer.start_transport/5`). `Acp.Connection.handle_response(:initialize)` then decides which post-`initialize` request to send.

A just-landed fix gates `session/load` behind the agent's advertised `loadSession` capability: when the agent does **not** advertise it, the launch degrades to `session/new` rather than failing the handshake with `-32601 "Method not found"` (the symptom users hit). That fix stops the crash, but it has a sharp consequence:

**`session/new` on a `:load` launch mints a brand-new conversation id and abandons the prior conversation — the agent loses all memory of it.** The currently-installed adapter, `claude-code-acp@0.13.x` (SDK `@agentclientprotocol/sdk@0.13`), is exactly this case: it **removed `loadSession`** and now advertises `agentCapabilities.sessionCapabilities.resume` instead. So today every resume / restart / terminal→rich switch of a Claude Code session silently starts a fresh conversation.

## Goal

Preserve **conversation continuity** across resume, desktop restart, and transport switch when the agent advertises ACP's `sessionCapabilities.resume`, by sending `session/resume`. The agent then retains the full prior conversation; the rich timeline starts empty (with an honest notice) and is fully context-aware from the first new turn.

### Non-goals (YAGNI)

- **Visible transcript repaint.** `session/resume`, by the adapter's documented contract, resumes "without replaying the message history" — it emits no `session/update` notifications for past turns. Rendering past messages would require parsing Claude Code's internal `<uuid>.jsonl` transcript: Claude-specific, format-fragile, remote-FS work on cloud runtimes, and a break of the "ACP is the abstraction, agent JSONL is the durable record" boundary. Explicitly deferred; revisit only if an adapter re-adds `loadSession` (which *does* replay).
- `session/fork` support.
- Any terminal-side resume change.

## Background: the capability reality

Verified against the installed adapter (`claude-code-acp@0.13.1`) and its bundled SDK (`@agentclientprotocol/sdk@0.13.0`):

- **`loadSession` is the adapter's method, not ours.** It lives in the external npm package. 0.13 dropped it. We cannot re-add it; we can only consume whatever the adapter advertises at runtime (authoritative).
- The adapter advertises `agentCapabilities.sessionCapabilities = { fork: {}, resume: {} }` (presence of the object = supported) and implements `unstable_resumeSession`, which the SDK routes from the **wire method `session/resume`**.
- **`session/resume` request** (`zResumeSessionRequest`): `{ sessionId, cwd, mcpServers?, _meta? }` — same shape as `session/load`.
- **`session/resume` response** (`zResumeSessionResponse`): `{ modes?, models?, configOptions?, _meta? }` — **no `sessionId`** (unlike `session/new`), carries mode/model config. So the response is handled like `session/load`'s: keep the existing `conversation_id`, surface config items.
- Internally the adapter passes `resume: sessionId` straight to the Claude Agent SDK `query()`, which reloads the conversation context but does **not** re-stream prior turns.

## Design

### 1. Capability ladder — `Acp.Connection.handle_response(:initialize)`

The single place the post-`initialize` request is chosen. For `launch.mode == :load`, choose by advertised capability, in priority order:

| Advertised capability | Request sent | Result |
| --- | --- | --- |
| `agentCapabilities.loadSession == true` | `session/load` | replays history (best; forward-compatible — no adapter offers it today) |
| `agentCapabilities.sessionCapabilities.resume` present | `session/resume` | **conversation continuity, no replay** ← the new path |
| neither | `session/new` | fresh conversation; continuity lost (last resort) |

`launch.mode == :new` is unchanged (always `session/new`).

A new request tag `:session_resume` is added to the fatal-handshake tag set (`:initialize / :session_new / :session_load / :session_resume`) so an error response to `session/resume` transitions the session to `:failed` (as the other handshake requests already do), rather than leaving it `:running` forever.

### 2. `handle_response(:session_resume, result)` — mirrors `:session_load`

- Keep `session_id = launch.conversation_id` (the resume response carries no `sessionId`).
- Emit `config_items(result)` (modes/models still surface to the timeline).
- Emit `{:session_ready}` (disarms the handshake watchdog).
- **Additionally** emit one persistent `notice` timeline item:
  - `id: "resume-notice"`, `type: "notice"`, `text`: *"Resumed — earlier messages aren't shown here, but the agent has the full conversation."*
  - It lands in the `AcpTimeline`, so a client attaching after resume sees it too.

Crucially, `:session_resume` does **not** emit `{:conversation_id, …}`. The persisted `conversation_id` stays stable across any number of resumes (same as `:session_load`), which is what keeps the on-disk transcript continuously resumable.

The notice is emitted **only** from the `:session_resume` handler. The degraded `:load`→`session/new` path (neither capability advertised) emits no notice item — only the `{:resume_strategy, :new}` log — because with `claude-code-acp` it is unreachable; if a neither-capability adapter is ever added, a louder "couldn't resume; started fresh" notice should be reconsidered then.

### 3. Detection helper

`resume_capable?(caps)` ≡ `is_map(get_in(caps, ["sessionCapabilities", "resume"]))`. ACP uses an empty object `{}` to mean "supported", so presence — not a boolean — is the test.

### 4. Observability

`handle_response(:initialize)` emits `{:resume_strategy, :load | :resume | :new}`; `SessionServer` logs it once at launch (e.g. `[acp <id>] resume strategy: session/resume (loadSession unavailable)`). The original bug was hard to diagnose precisely because nothing recorded which post-`initialize` path was taken; this single log line closes that gap. The existing `{:load_capable, load?}` effect is kept for back-compat (still ignored by `SessionServer`).

### 5. Frontend

`AcpConversation.svelte`: add one branch to the item loop — `{:else if item.type === 'notice'}` rendering a centered, muted single line (Legend tokens: `text-meta text-ink-3`, centered). No other frontend change; `acpSession.svelte.ts` already merges items by id.

### 6. Restart & resume

A desktop restart kills the Phoenix sidecar, so it behaves **identically to a resume** — it is just another `:load` relaunch through the same ladder. Two layers:

- **Visible rich timeline — lost.** The `AcpTimeline` is in-memory in the `SessionServer` process and dies with the backend. On boot, `Janitor.run/0` marks `:starting/:running` sessions `:interrupted`; the UI offers **Resume** (nothing auto-relaunches). On reopen the pane starts empty + the resume notice — no repaint (per non-goals).
- **Conversation continuity — preserved.** `conversation_id` is a persisted column (SQLite, OS app-data dir) and the Claude Code transcript JSONL lives on the local disk (`~/.claude/projects/<encoded-cwd>/<id>.jsonl`). Both survive a restart. On Resume, `start_transport/5` sets `mode = :load` from the persisted `conversation_id` → the ladder sends `session/resume` → the agent reloads full context.

**Cloud caveat.** The continuity guarantee above is for the local/desktop runtime (LocalPty), where `~/.claude` is on the persistent local disk. For cloud/sprite sessions, continuity instead depends on the sprite's filesystem surviving hibernation — a pre-existing open risk already flagged in the ACP rich-sessions spec (item #5, "to be confirmed in manual bring-up"). This design does not change that; it inherits it.

## Testing

**`Acp.Connection` unit tests:**

- `:load` + `sessionCapabilities.resume` → writes `session/resume` with the launch `sessionId`; emits the `notice` item, config items, `{:session_ready}`, and `{:resume_strategy, :resume}`.
- `:load` + `loadSession == true` (and resume also advertised) → still writes `session/load` (priority preserved); `{:resume_strategy, :load}`.
- `:load` + neither → writes `session/new`; `{:resume_strategy, :new}`.
- An error response to `session/resume` → `{:handshake_failed, reason}` effect (fatal).
- `:session_resume` keeps `conversation_id` (no `{:conversation_id, …}` effect emitted).

**`SessionServer` integration tests (Test runtime + Test ACP agent):**

- Resume of an ACP session whose adapter advertises `sessionCapabilities.resume` → server writes `session/resume` (not `session/new`), session stays healthy (no `:failed`), the `notice` item is broadcast, and `conversation_id` is unchanged after the handshake.
- (Existing) resume with `loadSession: true` still writes `session/load` — unchanged.

## Risks / to verify at live bring-up

- **Cross-transport resume by terminal-created id.** Confirm that `session/resume { sessionId: <terminal --session-id> }` actually resumes across the TUI→adapter boundary (the shared `~/.claude` store strongly implies yes; the adapter's `unstable_resumeSession` reads `params.sessionId` and passes it as `resume`, and the underlying Claude session id is the same uuid). Validate manually for both a clean terminal→rich switch and a restart→resume.
- **Empty-pane UX.** Confirm the resume notice reads clearly and the composer is immediately usable (the agent should answer the first new turn with full prior context).

## Rationale (decision log)

| Decision | Why |
| --- | --- |
| `session/resume` over JSONL repaint | Restores the high-value thing (agent memory) using the ACP-native method; avoids coupling Legend to Claude Code's internal transcript format and remote-FS reads; generalizes to any resume-capable adapter. |
| Capability ladder (load → resume → new) | Runtime-advertised capability is authoritative; prefers the richest method available; degrades gracefully instead of failing. Forward-compatible if `loadSession` returns. |
| Honest `notice` item instead of silent empty pane | The original confusion was an unexplained empty/failed pane. A one-line marker makes the "context kept, history not shown" state legible. |
| `{:resume_strategy, …}` log | The bug was hard to pin down because nothing recorded the chosen path; one log line makes future degradation diagnosable. |
| No visible repaint (non-goal) | Fragile, Claude-specific, breaks the ACP abstraction; deferred until an adapter offers `loadSession` again. |
