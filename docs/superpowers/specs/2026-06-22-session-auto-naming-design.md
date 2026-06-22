# Session auto-naming + rename — design

**Date:** 2026-06-22
**Status:** Approved (brainstorming) — ready for implementation plan

## Problem

Session names are entirely manual today. `Session.name` is an optional attribute
set only at `:start` (entered in `NewSessionDialog`); when left blank the UI falls
back to `name || harness_id` everywhere (session list, `SessionPane` header, the
signal `from_label`, the PTY nudge label). Users want names to appear automatically
instead of having to type one.

No name flows back from the harnesses, and for most there is no channel for one to:
terminal harnesses are a one-way CLI invocation (the only PTY write-back is the
debounced nudge line), and the ACP protocol carries message/thought/tool/plan/mode
updates but no session-title notification. So an automatic name has to be **derived
by us** from the text we already have — not fetched from the harness.

## Decisions (from brainstorming)

1. **Derivation:** truncate + clean the first prompt. **No LLM.** The backend
   orchestrates CLI agents and does not call models itself (only `:req` is present,
   no LLM SDK); adding a provider + key + latency + failure path is not justified
   for a naming feature.
2. **Coverage:** the two clean prompt sources only —
   - `instructions` set at `:start` (spawned/delegated sessions), and
   - the first **ACP** prompt text.
   Terminal-transport *interactive* sessions type directly into the PTY; capturing
   their first prompt would mean sniffing raw keystroke bytes (line editing, control
   sequences, bracketed paste). Out of scope — they keep the `harness_id` fallback
   until manually named.
3. **Rename:** session rename does **not** exist today (the `RenameSpace*` machinery
   is for *workspace spaces*, a separate frontend-only concept; the `Session`
   resource has update actions only for status transitions). It is added here so a
   user who left the name blank can fix an auto-name they dislike — especially for
   ACP sessions, where the auto-name appears *after* creation.

Auto-naming only ever **fills a blank name** (a manually-entered name always wins)
and derives **once** from the first prompt — it is never re-derived over the
session's life.

## Architecture

One pure deriver, two trigger sites, one shared `:rename` action.

```
                    ┌────────────────────────────────────┐
                    │ Legend.Core.Agents.SessionName       │
                    │   derive/1  (pure, no I/O)           │
                    └──────────────┬───────────────────────┘
                                   │ used by both triggers
        ┌──────────────────────────┴───────────────────────────┐
        │                                                        │
  create :start (atomic)                          SessionServer first acp_prompt
  blank name + instructions                       blank name + transport :acp
  → set name in the insert                        → Agents.rename_session/2 (deferred)
                                                          │
                                   update :rename ────────┘  (also: manual rename UI)
                                   after_transaction:
                                     Notifications.sessions_changed()   (lobby refetch)
                                     broadcast {:session_named, name} on "session:<id>"
```

### 1. `Legend.Core.Agents.SessionName` — pure deriver

New module, single function `derive/1`: prompt text in, clean title out or `nil`.

Rules:
- `nil` / blank / whitespace-only → `nil`.
- Choose the first non-blank line that is **not** a fenced-code-block marker.
- Strip markdown from that line: leading `#` / `>` / list markers (`-`, `*`, `1.`),
  inline backticks, emphasis (`*`/`_`), and `[text](url)` → `text`.
- Strip control characters; collapse internal whitespace runs to a single space.
- Ellipsize to a **~50-character** target on a word boundary, appending `…` when cut.
- Empty result → `nil`.

50 is the readable target; the 120 hard cap is enforced by the action validations
(below). Pure, no side effects, no I/O — exhaustively unit-tested.

### 2. Instructions trigger — atomic, inside `:start`

Add a `before_action` change to the existing `create :start`: when `name` is blank
**and** `instructions` is present, set `name = SessionName.derive(instructions)`
(skip when it returns `nil`). Because this runs inside the insert, the name is
correct in the create response with **no extra write and no broadcast**. The
existing blank-guard means a user-provided name is never overwritten.

### 3. `update :rename` — shared action

New update action on `Legend.Core.Agents.Session`:

```elixir
update :rename do
  require_atomic? false
  accept [:name]
  # trim; store nil when blank (resets to the harness_id fallback)
  validate match(:name, ~r/\A[^[:cntrl:]]*\z/u) do
    message "must not contain control characters"
    where present(:name)
  end
  validate string_length(:name, max: 120) do
    where present(:name)
  end
  change after_transaction(fn
    _changeset, {:ok, session}, _context ->
      Legend.Core.Agents.Notifications.sessions_changed()
      Phoenix.PubSub.broadcast(Legend.PubSub, "session:#{session.id}",
        {:session_named, session.name})
      {:ok, session}
    _changeset, {:error, _} = error, _context -> error
  end)
end
```

- Accepts **any** name — manual rename can overwrite freely. The "only-if-blank"
  guard lives at the auto-name **call site**, not in the action.
- The `after_transaction` fires **both** the lobby refetch signal
  (`sessions_changed/0`, identical to how every lifecycle transition notifies the
  list) **and** a targeted `{:session_named, name}` broadcast on the per-session
  topic. Every caller — manual or auto — therefore gets live updates for free.
- Code wrapper `Agents.rename_session(id, name)` for the SessionServer caller.

### 4. First-ACP-prompt trigger — deferred, in SessionServer

The first interactive prompt is only knowable in `SessionServer` at the first
`acp_prompt` cast. There, when `state.session.name` is blank and transport is `:acp`:

1. Flatten the ACP prompt content to plain text.
2. `SessionName.derive/1`; if non-`nil`, call `Agents.rename_session/2`, update the
   in-memory `state.session.name`, and set an `auto_named?` flag so it fires exactly
   once.
3. **Best-effort:** wrapped so a rename failure logs and the prompt is still sent —
   naming never blocks or fails a turn.

Triggers on the **live** first prompt only, not on `session/load` replay. A resumed
session that is still unnamed gets named on its next live prompt (accepted).

### 5. Manual rename — route + client

- Add a domain JSON:API route `PATCH /api/sessions/:id/rename` → `:rename`,
  mirroring the existing `/resume` and `/transport` routes in the `Legend.Core.Agents`
  domain.
- Frontend `renameSession(id, name)` in `frontend/src/lib/sessions.ts`, mirroring
  `resumeSession`/`setTransport`.

### 6. Frontend rename UI

- `SessionPane.svelte` header (`{session.name || session.harness_id}`, currently
  line 192) becomes **inline-editable**: click / pencil affordance → input → Enter
  commits via `renameSession`, Esc reverts. Inline edit (Linear-style) is lighter
  and more keyboard-first than a modal, matching the design register.
- `session_channel.ex`: add `handle_info({:session_named, name}, socket)` →
  `push(socket, "named", %{name: name})`; the pane updates `session.name` on that
  event. The session **list** already refetches on the lobby `"changed"` event, so
  it needs no change.

## Edge cases

- Blank / whitespace / punctuation-only prompt → `derive/1` returns `nil` → no
  auto-name; the `harness_id` fallback stays.
- Very long single token → hard-truncated at the target length with `…`.
- First line is a code fence → skip to the first prose line; none → `nil`.
- Manual name set at creation → auto-name never fires (blank-guard).
- Control characters → stripped by `derive/1` **and** rejected by `:rename`
  validation (defense-in-depth; the name flows into the PTY nudge label via
  `Terminal.nudge_line/3`).
- Queued/concurrent prompts → the `auto_named?` flag prevents a second derive.
- Rename DB/action failure → logged; the turn is unaffected.
- Resumed unnamed ACP session → named on the next live prompt, not on replay.
- Terminal-interactive session without instructions → not auto-named (documented
  gap); the user can rename manually.

## Testing

- **Unit (`SessionName.derive/1`):** table covering `nil`, blank, plain text,
  markdown header, fenced code, long single word, markdown link, multiline,
  embedded control chars, and a unicode boundary for the ellipsis cut.
- **Resource (`:start`):** fills `name` from `instructions` when blank; does **not**
  override a provided name; `nil` instructions leaves `name` `nil`.
- **Resource (`:rename`):** control-char + length validation; `after_transaction`
  fires `sessions_changed` and the `{:session_named, name}` broadcast
  (`assert_receive` on a subscribed PubSub).
- **SessionServer (ACP):** first `acp_prompt` names a blank session (persisted +
  broadcast); a pre-named session is left alone; a second prompt does not re-derive.
- **Channel:** the `"named"` push reaches an attached client on rename.
- **Frontend:** `bun run check` passes (repo's frontend testing is light).

## Out of scope (documented)

- Terminal-interactive PTY first-line sniffing.
- LLM-generated titles.
- Re-deriving / updating the name over a session's lifetime.

## Touched surfaces (for the plan)

- `backend/lib/legend/core/agents/session_name.ex` (new — pure deriver)
- `backend/lib/legend/core/agents/session.ex` (`:start` change; `update :rename`)
- `backend/lib/legend/core/agents.ex` (`rename_session/2` code interface)
- `backend/lib/legend/core/agents/` domain JSON:API routes (`/:id/rename`)
- `backend/lib/legend/core/agents/session_server.ex` (deferred ACP trigger +
  `auto_named?` state + prompt-content flattening)
- `backend/lib/legend_web/channels/session_channel.ex` (`{:session_named, …}` →
  `"named"` push)
- `frontend/src/lib/sessions.ts` (`renameSession`)
- `frontend/src/lib/components/sessions/SessionPane.svelte` (inline-editable header +
  handle `"named"`)
- Tests across the above.
