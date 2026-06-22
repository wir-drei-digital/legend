# Session grouping by working directory

- **Date:** 2026-06-22
- **Status:** Draft (awaiting review)
- **Scope:** Frontend (`frontend/`) + one small backend change (cwd normalization on `:start`). One new **optional** Tauri dependency (`tauri-plugin-dialog`) for the desktop folder picker, isolated as the final slice.

## Problem

The session list (`SessionsSource.svelte`) is one flat list sorted by attention →
running → idle, then recency. Once you run more than a handful of agents across
different projects, there's no way to see "everything happening in project X" —
sessions for unrelated work interleave. Other desktop harnesses (Conductor,
Crystal, …) group sessions by their working directory so the list reads as
"projects, each with its agents." Legend should too.

Two supporting gaps:

1. The create modal's working-directory field is a bare free-text `Input`. To
   make grouping *cohere*, picking the **same** folder twice must be trivial —
   a fat-fingered near-miss path (`/Users/x/proj` vs `/Users/x/proj/`) would
   split one project into two groups.
2. Remote (Sprites) sessions have no meaningful host filesystem path, and the
   user flagged them as possibly needing different treatment.

## Goal

Group the session list into **collapsible directory groups**, one per working
directory, headed by the folder name with a session count. Make the create
modal's directory field a **picker** (typeahead over existing project dirs +
free text, plus a native Browse button on desktop) so sessions reliably land in
the right group.

## Non-goals

- **No new backend entity.** Grouping keys off the existing `cwd` attribute via a
  single client-side helper; no `Project`/`Workspace` Ash resource. (The clean
  future extension — an optional `workspace` *label* that defaults to the folder
  basename — slots in behind the same helper without touching the list UI.)
- **No sprite-based remote grouping.** Each Sprites session provisions its own
  sprite named by session id (`ensure_sprite(session_id)`), so sprite == session
  today — there is nothing to group by. Remote sessions group by `cwd` like the
  rest, with a cloud marker. Revisit when a sandbox can host multiple sessions.
- **No git-root detection / monorepo magic.** The group is the literal chosen
  directory.
- **No reordering of groups by the user**; order is derived (see below).

## Resolved decisions (from brainstorming)

1. **Group key = working directory** (`session.cwd`), not a first-class entity.
   Lightest path; `cwd` already exists and already flows to both runtimes
   (`LocalPty` via `{:cd, cwd}`, `Sprites` via the cloud exec) and ACP.
2. **Folder doubles as the workspace anchor for role agents.** An OpenClaw sales
   agent or Hermes inbox manager isn't folder-shaped — but giving each its own
   home folder (even an empty `~/agents/sales`) separates them into their own
   groups with zero new model. Collaborators share a folder → same group.
   Spawned children already inherit the parent's cwd (`cwd || session.cwd`), so
   delegation lineage stays in one group automatically.
3. **Remote = uniform cwd grouping + cloud marker, richer model deferred** (per
   Non-goals).
4. **Group order by recency**, attention floats up (see Architecture).
5. **cwd normalization** at the backend so near-miss paths collapse into one
   group.
6. **Nudge away from `~`, don't forbid it.** Running an agent in the bare home
   dir is a footgun (broad access to keys/dotfiles/all projects). The modal makes
   the working dir a prominent, encouraged field and shows an inline caution when
   it would resolve to home — but Start stays enabled (role agents can still opt
   into home). `~` remains the silent backend fallback for API/legacy callers.
   Creating a workdir is covered by the native picker's built-in "New Folder".

## Architecture

### A. Grouping logic (client-side, one helper)

A single pure helper module `src/lib/shell/sessionGroups.ts` owns the rule so the
list UI never hard-codes it:

- **`groupKey(session): string`** — returns `session.cwd` (already normalized by
  the backend; see C). The `Session.cwd` type is `string | null`; a `null`/empty
  value (only possible on legacy rows predating the home default) maps to a single
  sentinel key labeled `"No directory"`, so such rows still bucket deterministically
  rather than each forming a one-off group.
- **`groupLabel(key): string`** — the sentinel → `"No directory"`; the home dir →
  `"Home"`; otherwise the last path segment (basename). Full path rides along as
  the header `title` (hover).
- **`groupSessions(rows: Row[]): Group[]`** — operates on the **existing `Row`
  view-model** (already carries `state` + `lastActive`), so the helper stays pure
  (no stores/runes). Buckets by `groupKey(row.session)`, sorts **within** each
  group by the existing rank (attention → running → idle, then recency), and
  orders the **groups** by:
  1. groups containing an attention-needed session first, then
  2. most-recent activity in the group (max `lastActive`) descending.

  Returns `{ key, label, fullPath, rows, hasAttention, lastActive }[]`. Pure
  function (no runes) → unit-testable with plain `Row` fixtures.

`Group` is purely a view-model; nothing is persisted server-side.

### B. Session list UI (`SessionsSource.svelte`)

`SessionsSource` is itself the outer Dock section (its `open`/`ontoggle` collapse
the whole "Sessions" panel). Directory groups are a **second, lighter level of
collapse inside** it:

- The flat `{#each rows}` becomes `{#each groups}` → a small **group header row**
  + the group's rows (the existing `benchRow` snippet is reused unchanged).
- **Group header:** a compact row (shorter than the section bar) — chevron +
  folder icon + `groupLabel` + count, `title={fullPath}`. Styled with Legend
  tokens (`text-micro`/`text-ink-3`, `border-hair`), in the spirit of
  `SectionLabel`. Clicking toggles that group.
- **Per-group collapse state** persists to its own localStorage key
  `legend:sessions:groups` → `{ [key]: boolean }`, default **open**. (Separate
  from the Dock's `legend:dock` `openSections`, which is per-source.)
- **Remote marker:** rows whose `runtime_id !== 'local_pty'` get a small `cloud`
  glyph (before the harness tag) so cloud sessions are visible within whatever
  group they land in.
- **Search** still filters sessions (existing `query`); groups recompute and
  empty groups disappear. The empty/Connecting message is unchanged.
- **Single-group degenerate case:** when every session shares one directory
  (common early on), still render the one header — it shows the project name and
  count, and collapsing it is harmless. (No special-casing; keeps the code one
  path.)

The section-bar count (`sessionsStore.sessions.length`) is unchanged.

### C. Backend — cwd normalization on `:start`

One `change` on the `:start` action (`session.ex`) normalizes `cwd` so grouping
keys are consistent. Normalization is **runtime-aware** — it must not assume the
backend host's filesystem for remote runtimes:

- **Local runtime** (`local_pty`): expand a leading `~` to the backend user's
  home, absolutize, and strip any trailing slash (except root). Implemented with
  `Path.expand/1` guarded to only `~`/already-absolute inputs (never resolve a
  bare relative path against the unpredictable backend cwd — reject or leave such
  input untouched).
- **Remote runtimes** (e.g. `sprites`): treat the path as opaque — strip the
  trailing slash only; no host-home expansion.

This runs before the existing transport/spawn changes and is order-independent of
them. The `default_cwd/0` (home) default is unchanged. No migration needed
(`cwd` column already exists); legacy rows keep whatever they have.

### D. Create-modal picker (`NewSessionDialog.svelte`)

Replace the bare `cwd` `Input` with a small **typeahead + suggestions** block,
built from existing primitives (no new shadcn dep):

- The `Input` stays for free-text entry.
- Below it, a **suggestion list of existing project directories** — the distinct
  `cwd`s from `sessionsStore.sessions`, filtered by what's typed, each rendered
  as a clickable row (folder icon + basename + dimmed full path). Clicking fills
  the input. This is what makes grouping cohere: you reuse a known project dir
  instead of retyping it.
- **Desktop only — "Browse…" button** (final, isolated slice): uses
  `tauri-plugin-dialog`'s `open({ directory: true })` to set the field from a
  native folder picker. Hidden on web (the SPA can't pick a server-side folder);
  the Tauri check reuses the existing `__TAURI_INTERNALS__` guard pattern. The
  macOS picker's built-in **"New Folder"** is the create-a-workdir path — no
  custom folder-creation UI needed.
- **Home-dir nudge** (decision 6): when the field is empty or resolves to the
  home dir, render an inline caution beneath it (muted warning text, Legend
  tokens) — e.g. "Agents here can read everything in your home folder. Pick or
  create a project folder." **Non-blocking** — Start stays enabled. The field is
  also given more prominence than today's afterthought `Input` (clear label +
  the suggestion/Browse affordances above).
- The remote-runtime placeholder behavior (the existing
  `selectedRuntime.id !== 'local_pty'` branch) is preserved; the home-dir caution
  is local-runtime only (a remote path isn't the host's home).

The submit payload is unchanged (`cwd` already sent when non-empty).

## Data flow

```
create modal ─► pick/browse/type cwd ─► createSession({cwd}) ─► :start
   :start ─► normalize cwd (runtime-aware) ─► persist
list render ─► groupSessions(sessions) ─► {#each groups}
                 header(toggle, persisted in legend:sessions:groups)
                 └► rows (existing benchRow, + cloud glyph if remote)
```

## File plan

**New**
- `frontend/src/lib/shell/sessionGroups.ts` — `groupKey` / `groupLabel` /
  `groupSessions` (pure; unit-tested).
- `frontend/src/lib/shell/sessionGroups.test.ts` — Vitest for bucketing, within-
  group rank, group ordering (attention-first then recency), label/home cases.

**Modified**
- `frontend/src/lib/components/shell/sources/SessionsSource.svelte` — render
  groups + collapsible headers + per-group localStorage; cloud glyph on remote
  rows; reuse `benchRow`.
- `frontend/src/lib/components/NewSessionDialog.svelte` — directory picker
  (typeahead suggestions from existing cwds; Tauri Browse button; inline
  home-dir caution).
- `backend/lib/legend/core/agents/session.ex` — runtime-aware `cwd`
  normalization `change` on `:start` (+ a small private helper).
- `backend/test/legend/core/agents/session_test.exs` (or nearest existing) —
  normalization cases (local `~`/trailing-slash/absolute; remote opaque).

**Dependency (final slice, optional)**
- `desktop/src-tauri/Cargo.toml` + `tauri.conf.json` + `capabilities/default.json`
  + `frontend/package.json` — add `tauri-plugin-dialog` and its `dialog:allow-open`
  capability for the native folder picker. Cleanly separable: cut this slice and
  the picker still works (typeahead + free text), just without native Browse.

## Testing

- **Vitest** (`sessionGroups.test.ts`): pure grouping/ordering/label logic.
- `cd frontend && bun run check` (0/0) and `bun run build`.
- **Backend:** `cd backend && mix test` for the normalization helper; `mix precommit`.
- **Live (CDP) click-through:** create two sessions in dir A and one in dir B →
  two groups, correct labels + counts; collapse a group → persists across reload;
  start a session in a new dir → new group appears, ordered by recency; a remote
  (sprites) session shows the cloud glyph; filter narrows groups and hides empty
  ones; the modal's Browse button (desktop) sets the field and the suggestion
  list offers existing dirs; leaving the dir empty/home shows the inline caution
  while Start stays enabled.

## Risks & caveats

- **Group-key consistency hinges on normalization.** If a path slips through
  un-normalized (e.g. a relative input we chose to leave untouched), it forms its
  own group. Acceptable — the picker steers users toward existing absolute dirs,
  and the helper is the single chokepoint to tighten later.
- **Runtime-aware normalization must not host-resolve remote paths** — `~`
  expansion against the backend home would be wrong for a sandbox. Guard on
  runtime id; remote = trailing-slash strip only.
- **Two localStorage namespaces** (`legend:dock` per-source vs
  `legend:sessions:groups` per-directory) — keep them distinct; a stale/oversized
  groups map is harmless (unknown keys default open, ignored otherwise).
- **`tauri-plugin-dialog`** adds a Rust dep + capability; the binary/permission
  wiring is the usual sync points (Cargo, conf, capabilities). Isolated as the
  last slice so the core ships without it if desired.
- **Role-agent ergonomics:** folder-as-workspace means a user wanting separate
  groups for two home-dir role agents must give them distinct folders. If this
  proves clumsy in practice, the deferred optional `workspace` label is the clean
  next step (behind the same `groupKey` helper).

## Documentation updates

- `ARCHITECTURE.md` — the frontend session list now groups by `cwd` via the
  `sessionGroups` helper; backend `:start` normalizes `cwd` (runtime-aware); note
  the deferred `workspace`-label extension point and the sprite-grouping deferral.
- `DESIGN_SYSTEM.md` — the in-list collapsible group header pattern (second-level
  collapse inside a Dock source) and its token usage.
