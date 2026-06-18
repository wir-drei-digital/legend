# Source Dock — unified, draggable content source for the tiling workspace

- **Date:** 2026-06-18
- **Status:** Draft (awaiting review)
- **Scope:** Frontend only (`frontend/`). No backend changes.

## Problem

Setting up a workspace is confusing. Each space type carries its own special
rail (the Sessions **bench**, the Library **file tree**) and a custom space is
an empty void with no in-place way to add content — you have to reopen the
Cmd+K launcher and hunt through "Open." The per-space rails are special-cased in
the shell, and the same things (your sessions, your files) are reachable
differently depending on which space you're in.

## Goal

Replace the per-space rails with **one persistent source dock** that is the
single place to find and add content, available in every space. You add content
by **clicking** an item (opens into the active space) or **dragging** it into
the grid (precise side-by-side placement). The workspace restores its full last
state on launch. Spaces become uniform tiling grids.

This is the concrete realization of the agentic-OS direction: surfaces are
pluggable, sources are pluggable, and you compose a workspace by pulling content
from the dock into tiles.

## Non-goals

- No new surface kinds (still `session` / `file` / `messages`). The dock's
  source list is extensible, but only Files + Sessions ship now.
- No backend changes; no cloud sync (persistence stays localStorage via the
  existing adapter seam).
- No multi-window / OS-window spawning — "window" here means a tile in the grid.
- No reordering of dock sections by the user (fixed order now).

## Resolved decisions (from brainstorming)

1. **Unify** — the dock replaces the per-space rails entirely; spaces are just
   grids + the global dock.
2. **Click + drag** — click opens into the active space; drag places precisely
   via the existing i3 drop zones. Drag is pointer-based (matches `TileGrid`).
3. **Restore last state on open** — every space (Sessions included) restores its
   exact tile layout; a freshly-started session **auto-appears** in the Sessions
   space unless already placed elsewhere; stopped/deleted sessions restore as
   resume/unavailable tiles.
4. **Details is per-tile** — an in-window info panel on each file/session
   surface (it belongs to that file/session), hidden by default, toggled from
   the tile header, reusing the generic `SidePane` primitive.

## Architecture

### The Dock (`src/lib/components/shell/Dock.svelte`)

A persistent, collapsible left panel rendered by `LegendShell` for every space
(replacing the per-space rail branch). It renders an ordered list of **dock
sources**, each a collapsible section.

- **`DockSource` contract** (`src/lib/shell/dock-sources.ts`): `{ id, label,
  icon, component }`. `DOCK_SOURCES` is the ordered registry. Ships:
  `files` → `FilesSource`, `sessions` → `SessionsSource`. Future sources
  (messages, calendar) add one entry + one component.
- **Collapse:** each section collapses (accordion, state persisted per section);
  the whole dock collapses to reclaim width (a thin reopen affordance remains).
  Dock width fixed at 210px (was 178 for the bench); collapse state persists to
  localStorage (`legend:dock`).
- The dock is **state-agnostic** about spaces — it lists sources and emits open
  intents; the workspace store decides placement.

### Dock sources

- **`FilesSource.svelte`** — the library tree + filter + "＋ new file" (today's
  `LibraryRail` content, relocated verbatim where possible). Each file row is a
  **drag source** (payload `{kind:'file', params:{path}}`) and click-to-open.
  A file already open as a tile in the active space shows a subtle "open" dot.
- **`SessionsSource.svelte`** — the session list grouped by status (needs-you /
  running / idle) with status dots + unread counts (today's `SessionBench`
  content). Each row is a drag source (`{kind:'session', params:{sessionId,
  name}}`) and click-to-open. A session already tiled in the active space shows
  the "open" marker; the old "watching" group is dropped (placement is now
  per-space).

### Open & drag

A new shared **drag state** (`src/lib/shell/dock-drag.svelte.ts`): `{ payload:
{kind, params} | null, x, y }`. A dock row's `pointerdown` (past a small
threshold) sets `payload` + tracks the pointer via window listeners and renders
a ghost; `pointerup` clears it.

- **Click (no drag):** `workspaceStore.openSurface(kind, params)` — opens into
  the active space, focusing an existing tile if the surface is already there
  (dedupe via `SURFACES[kind].key`), else appending a tile.
- **Drag:** while `dockDrag.payload` is set, `TileGrid` shows i3 drop zones over
  its tiles (reusing its existing `hitTest`); on `pointerup` over the grid it
  calls `workspaceStore.openSurface(kind, params, { targetId, side })`. Dropping
  on empty space (no tiles) just appends.
- **`openSurface(kind, params, placement?)`** gains an optional
  `placement: { targetId, side }`: after minting + binding the tile and
  `layout.add(id)`, it calls `layout.dropRelative(id, targetId, side)` to move
  the new tile to the drop target (reuses the existing tree op). Without
  placement, behavior is unchanged (focus-or-append).

`TileGrid` already owns intra-grid tile dragging; it gains an "external drop"
mode driven by `dockDrag` — same drop-zone hit-testing, different commit
(`openSurface` instead of `dropRelative`-move).

### Spaces become uniform

`LegendShell` stops branching on `space.auto`/`space.rail`/`space.side`. Every
space renders: **Dock** (left, persistent) + the active space's **`TileGrid`**
(fills the rest). No per-space rail or side chrome. `WorkbenchLayout` is no
longer used for spaces (kept for any other future use, or retired if unused).
Seeded spaces: **Sessions** (auto-appends running sessions) and **Library**
(now a plain grid — its tree lives in the dock). `Space.rail`/`Space.side` fields
are removed.

### Per-tile Details

Each content surface can reveal an in-window info panel, hidden by default,
toggled from its header (a `panel-right`/info `IconButton`). It renders the
generic `SidePane` **inside** the tile (right edge, ~260px, over/with the body).

- **`FileSurface`** — path, type, size, modified (from `libraryStore.entries`) +
  a "Copy reference" footer (the retired Library Details content, now per-tile).
- **`SessionSurface`** — name, harness, runtime, cwd, status, and delegation
  lineage (`spawned_by_session_id`) from the `Session` object.

The standalone `LibrarySide.svelte` (space-level Details) is retired.

### Persistence + session reconcile

Extend the existing snapshot/hydrate (`workspace-persistence.ts` /
`workspaceStore`):

- **Snapshot every space's layout, including the auto Sessions space** (today it
  is persisted as an empty marker). Session tiles persist their binding
  (`{kind:'session', params:{sessionId, name}}`) in whatever space they live.
- **Hydrate restores all spaces' tiles**, then a reconcile pass runs:
  - A **running** session that is **not tiled in any space** is appended to the
    Sessions space (so newly-started agents auto-appear).
  - A restored session tile whose session is **stopped** renders a resume tile
    (`SessionSurface` already handles this).
  - In the **Sessions** space, a session tile whose session no longer exists
    (deleted) is pruned; in **other** spaces it renders the tolerant
    "unavailable" tile (the user placed it; they close it).
- Bump `WORKSPACE_SCHEMA` (the Space shape changed: `rail`/`side` removed). The
  tolerant loader resets to seeded defaults on mismatch.

## Data flow

```
Dock row click ─────────────► workspaceStore.openSurface(kind, params)
Dock row drag ──► dockDrag.payload set ──► TileGrid shows drop zones
                                        └► pointerup over grid ─►
                                           openSurface(kind, params, {targetId, side})
launch ─► hydrate(all spaces) ─► reconcile: append unplaced running sessions
tile header ℹ ─► surface.detailsOpen toggles in-window SidePane
```

## File plan

**New**
- `src/lib/components/shell/Dock.svelte` — the persistent dock shell.
- `src/lib/shell/dock-sources.ts` — `DockSource` contract + `DOCK_SOURCES`.
- `src/lib/components/shell/sources/FilesSource.svelte` — files tree section.
- `src/lib/components/shell/sources/SessionsSource.svelte` — sessions list section.
- `src/lib/shell/dock-drag.svelte.ts` — shared dock→grid drag state.

**Modified**
- `src/lib/components/shell/LegendShell.svelte` — render `Dock` + active grid;
  drop the per-space rail/side branching and the `*Empty` rail-dependent text.
- `src/lib/components/shell/TileGrid.svelte` — external-drop mode driven by
  `dockDrag` (drop zones + commit via `openSurface`).
- `src/lib/shell/workspace.svelte.ts` — `openSurface(kind, params, placement?)`;
  placement-aware insert; reconcile = restore + append-unplaced-running; drop
  `rail`/`side` from `Space`; snapshot/hydrate include the Sessions space.
- `src/lib/shell/workspace-persistence.ts` — `WorkspaceSnapshot` shape (no
  `rail`/`side`), schema bump.
- `src/lib/components/library/FileSurface.svelte` — in-tile Details toggle +
  `SidePane`.
- `src/lib/components/surfaces/SessionSurface.svelte` — in-tile Details toggle +
  `SidePane` (session info).
- `src/lib/components/sessions/SessionBench.svelte` — content relocated into
  `SessionsSource` (then removed if no other reader).
- `src/lib/components/library/LibraryRail.svelte` — content relocated into
  `FilesSource` (then removed).

**Retired**
- `src/lib/components/library/LibrarySide.svelte` (Details → per-tile).
- The empty-state `AsteroidsGame` keeps its place; the dock now provides the
  add-content path, so the empty-state caption can simply point at the dock.

## Testing

- **Vitest** for the pure additions: `openSurface` placement insertion order and
  the "append running sessions not placed in any space" reconcile (extract the
  set logic as a pure helper so it's testable without runes).
- `cd frontend && bun run check` (0/0), `bun run test`, `bun run build`.
- **Live (CDP) click-through:** dock visible in every space; click a file/session
  → opens in active space; drag a dock item onto a tile's left/right/top/bottom →
  precise placement; reload restores all spaces + tiles; start a new session →
  auto-appears in Sessions; stopped session → resume tile; per-tile Details
  toggles open/closed; dock + section collapse persists.

## Risks & caveats

- **Cross-component drag (dock → grid)** is the novel bit; the shared `dockDrag`
  state + reusing `TileGrid`'s hit-testing keeps it consistent with intra-grid
  re-tiling. Pointer capture must be released on `pointercancel`.
- **Shell restructure** removes the per-space rail/side branching that the tiling
  workspace just shipped — guard with the live parity check (Sessions + Library
  still work, just sourced from the dock).
- **Reconcile change** (restore + append-unplaced vs wholesale reconcile) must
  not double-place a session that's in a custom space; key the "placed" check on
  *all* spaces' bindings.
- Persisted-state migration: schema bump + tolerant reset; a one-time loss of
  saved layout on upgrade is acceptable (local PoC).

## Documentation updates

- `ARCHITECTURE.md` — the dock + `DockSource` contract, the dock→grid drag
  protocol, uniform spaces (rails retired), per-tile Details, the
  restore-last-state + auto-append-sessions reconcile.
- `DESIGN_SYSTEM.md` — `Dock` as a first-class shell primitive; `SidePane` now
  also used in-tile.
- `VISION.md` — sources as pluggable as surfaces ("pull content from the dock
  into the workspace").
