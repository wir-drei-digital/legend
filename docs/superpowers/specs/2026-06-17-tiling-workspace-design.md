# Tiling Workspace — windowing core for the agentic OS

- **Date:** 2026-06-17
- **Status:** Draft (awaiting review)
- **Scope:** Frontend only (`frontend/`). No backend changes.

## Problem

Tiling exists today only inside the Sessions view: `watchset.svelte.ts` (the
i3-style layout model) and `WatchSetGrid.svelte` (the grid view) both hard-wire
`SessionPane` as the only thing a tile can hold. Navigation is a *separate*
mechanism (`views.ts` + the Cmd+K "Spaces" overlay), and the Library view is a
*third* mechanism (`WorkbenchLayout` with a single `<textarea>`). Three layout
systems, none reusable.

We want tiling to be the **windowing core of the whole app** — the primitive
the shell is built on, not a feature of one view. Legend is an agentic OS: you
run agent harnesses, files, messages, and (later) calendar/email side by side,
arranged how you like. This is the concrete realization of VISION.md principle 4
("Harnesses, runtimes, tools, integrations, and **UI panels** are extension
points") — a *surface* is a pluggable UI panel that tiles anywhere.

The product spine is **strong defaults, deep flexibility**: a first-timer lands
in default spaces that behave exactly like today's Sessions and Library; a power
user opens any surface into any space, rearranges by drag, and saves custom
spaces. The same launcher API that a human uses to open a tile is what an *agent*
would later call to arrange the UI — enabled by this design, not built in it.

## Goals

- Extract a content-agnostic **windowing primitive** (`TileLayout` model +
  `TileGrid` view) that knows nothing about sessions, files, or surfaces.
- Render tiles in a **flat positioned layer** so a tile's component is mounted
  once and never remounts on re-tile — terminals never tear down or rejoin the
  PTY when dragged or split.
- Introduce a **surface registry** (`kind → component + chrome`) so new tileable
  content is one entry + one component.
- Make **Spaces** real tiling workspaces: named layouts of surfaces, switchable
  and persisted, with optional per-space rail/side chrome. Ship two seeded
  defaults (Sessions, Library) that reproduce today's experience exactly.
- Add an **app launcher** (evolved Cmd+K overlay): switch/create spaces, open a
  surface into the active space, open a modal.
- Add a **modal layer** for secondary/config views; move Settings into it.
- Migrate the three primary content types onto surfaces: session, file,
  messages. File surfaces support **single-editor + split-on-demand**.
- Persist spaces to `localStorage` through an **adapter seam** so a future
  SQLite-backed, cross-device-synced adapter is a drop-in replacement.

## Non-goals (explicit; each a later spec)

- Calendar / email / any new surface kind beyond session, file, messages.
- Backend or cloud sync of spaces. localStorage only this cycle; the adapter
  seam is the entire forward-compat investment.
- Agent-driven layout. The `openSurface`/`splitActive` API is the seam an agent
  would use, but no agent integration is built.
- Tabs-within-a-tile, floating/overlapping windows, picture-in-picture.
- Mobile / responsive workspace. Desktop and web (Tauri + browser) only;
  tiling assumes a pointer and a wide viewport.
- No new backend endpoints. Sessions, messages, and the library file API
  already exist and are consumed as-is.

## Architecture

Four layers, bottom-up. Each is ignorant of the layer above it.

### 1. `TileLayout` — the windowing model

`src/lib/shell/tiling.svelte.ts`. A runes class, extracted verbatim-in-spirit
from the generic half of today's `WatchSet`. Deals only in **opaque string tile
ids**.

State:
- `columns: string[][]` — left→right columns, each a top→bottom stack of tile
  ids (the i3-style tree).
- `colSizes: number[]`, `rowSizes: number[][]` — per-column and per-column-row
  flex-grow weights (empty/short ⇒ equal).
- `focusedId: string | null` — zoom one tile to fill the grid.
- `activeId: string | null` — the highlighted / input-target tile.
- `draggingId: string | null` — the tile being dragged.

Operations (all present today, names preserved where possible):
- `add(id)` — append as a new right-hand column.
- `remove(id)` — drop the tile; collapse empty columns.
- `dropRelative(id, targetId, side)` — re-tile relative to a target
  (`left`/`right` insert a column; `top`/`bottom` split the target's column).
- `focus(id)` / `restore()` / `setActive(id)`.
- `startDrag(id)` / `endDrag()`.
- `colFlex(ci)` / `rowFlex(ci, ri)` / `setColSizes(sizes)` /
  `setRowSizes(ci, sizes)`.
- getters: `tiles` (flat ids), `tileCount`, `has(id)`.
- `serialize()` / `deserialize(snapshot)` — plain-object snapshot of
  `{columns, colSizes, rowSizes, focusedId, activeId}` for persistence (distinct
  from `restore()`, which un-zooms focus).

`MAX_TILES`, `#dismissed`, `promote`, `evict`, and `reconcile` do **not** live
here — those are session-specific and move to the workspace store's auto driver
(below).

### 2. Surface registry — what a tile holds

`src/lib/shell/surfaces.ts`.

```ts
export interface SurfaceDef<P = Record<string, unknown>> {
  kind: string;
  title: (params: P) => string;        // tile header + launcher label
  icon: IconName;
  dragLabel?: (params: P) => string;   // ghost overlay; defaults to title()
  component: Component;                 // body+header; props { tileId, params, grab }
  /** stable key for dedupe ("focus existing instead of duplicate") */
  key?: (params: P) => string;
}

export const SURFACES: Record<string, SurfaceDef>;
```

A **tile binding** is `{ id: string; kind: string; params: object }`. The
`TileGrid`'s `tile` snippet receives a tile id; the space renderer looks up the
binding, finds `SURFACES[kind]`, and renders `component` with
`{ tileId, params, grab }`. `grab` is the pointer-drag starter the grid provides;
the surface wires it to its own header drag region (today's `SessionPane`
contract).

Registered this cycle: `session` (`{sessionId}`), `file` (`{path}`),
`messages` (`{}`, a singleton — `key` returns a constant so a second open just
focuses the existing tile).

### 3. Space — a named tiling workspace

`src/lib/shell/workspace.svelte.ts` — `workspaceStore` (runes singleton).

```ts
interface Space {
  id: string;
  name: string;
  layout: TileLayout;
  bindings: Map<string, { kind: string; params: object }>;
  rail?: Component;          // optional left chrome (e.g. SessionBench, file tree)
  side?: Component;          // optional right chrome (e.g. Library Details)
  auto?: 'sessions';         // auto-populates tiles from live sessions
  sideOpen?: boolean;
  sideWidth?: number;
}
```

`workspaceStore` owns: `spaces: Space[]`, `activeId`, and the operations:
- `switchSpace(id)`.
- `createSpace(name?)` — empty manual space.
- `saveSpace()` / `renameSpace(id, name)` / `deleteSpace(id)`.
- `openSurface(kind, params)` — dedupe via `SURFACES[kind].key`; if present,
  focus it; else mint a tile id, set `bindings`, `layout.add(id)`, set active.
  Operates on the active space.
- `closeTile(tileId)` — `layout.remove`, delete binding (surfaces may veto/confirm
  first via their own UI — see file unsaved guard).
- `splitActive()` — duplicate the active tile's `{kind, params}` into a new tile
  beside it.
- `setActiveTileParams(params)` — re-point the active tile (the Library tree's
  mechanism).

**Seeded default spaces** (strong defaults):
- **Sessions** — `rail: SessionBench`, `auto: 'sessions'`, no side. Tiles are
  session surfaces.
- **Library** — `rail: <file tree>`, `side: <Details>`, no auto. Tiles are file
  surfaces; split-on-demand.

**The `auto:'sessions'` driver** reproduces today's behavior. The workspace store
subscribes to `sessionsStore`; on change it reconciles *only the auto space's*
bindings against live running sessions — add new sessions as tiles, drop dead
ones, honor a per-space `#dismissed` set (the × button), respect the 6-tile cap.
This is today's `watchset.reconcile`/`#dismissed`/cap logic, relocated and scoped
to one space. Manual spaces are never auto-reconciled.

### 4. Modal layer — secondary/config views

`src/lib/components/shell/ModalHost.svelte` + `Modal.svelte`. A shell-level
overlay stack. `shell.openModal(id)` / `closeModal()`. Esc and backdrop close.
Settings (and future config screens) render here — never tiles, never routes.
In-UI only; no `window.confirm`/`alert` (Tauri no-ops them, per CLAUDE.md).

## Flat positioned rendering (`TileGrid`)

`src/lib/components/shell/TileGrid.svelte`. The novel part, and the reason
terminals survive re-tiling.

**Props:** `layout: TileLayout`, `tile: Snippet<[id: string, grab: (e:
PointerEvent) => void]>`, `empty?: Snippet`, `dragLabel?: (id) => string`,
`minColPx = 160`, `minRowPx = 90`.

**Render model:** every tile id is rendered exactly once, keyed at the top level
of a single flat container (`{#each layout.tiles as id (id)}`). A tile id never
moves to a different parent or `{#each}` block, so its component (and any xterm
inside it) **never unmounts on re-tile**. Position is purely presentational:

- The container measures its pixel size (`ResizeObserver` / `bind:clientWidth`
  + `clientHeight`).
- A pure function `computeRects(columns, colSizes, rowSizes, W, H, seam)` walks
  the tree and returns `Map<tileId, {left, top, width, height}>`: distribute `W`
  across columns by `colFlex` (minus seam widths), then each column's `H` across
  its rows by `rowFlex`. Lives beside `TileLayout` and is unit-tested.
- Each tile is `position:absolute` with its rect applied via
  `transform: translate(left, top)` + `width`/`height`. Rect changes animate via
  a CSS transition on transform/size for the "buttery" feel; the transition is
  suppressed while `draggingId` is set (drag must track the pointer 1:1).
- **Focus-zoom:** when `layout.focusedId` is set, the focused tile's rect = full
  container; all other tiles stay **mounted** but `visibility:hidden` +
  `pointer-events:none` (state preserved, terminals alive). `restore()` returns
  them to their computed rects.
- **Resize seams** are absolutely-positioned overlays drawn between adjacent
  rects (a 1px `bg-hair` line with a wider invisible pointer target). Drag math
  is today's `beginColResize`/`beginRowResize`, retargeted to write `colSizes`/
  `rowSizes`.
- **Drag-to-retile:** today's `beginDrag`/`hitTest` (directional split detection
  against tile rects), the ghost overlay, and the drop highlight, all preserved.
  On drop → `dropRelative`; the moved tile's rect animates to its new slot.
- **Empty state:** the `empty` snippet renders when `layout.tiles` is empty.

This is a more involved component than the nested-flex original, but it is the
foundation a "core primitive" deserves and removes the remount/rejoin cost
entirely.

## Key behaviors & data flow

**Opening a surface.** Launcher (or any caller) → `workspaceStore.openSurface(
kind, params)`. Dedupe by `key`; focus-or-create; the new tile appears as a new
column in the active space and becomes active.

**Sessions space (auto).** Live sessions reconcile into tiles exactly as today;
the user can still drag/resize/zoom/evict within the space. Eviction adds to the
space's `#dismissed` so a dead-then-revived session is not auto-refilled until
promoted. (Manual rearrangement of auto tiles is best-effort across reloads —
the auto driver may re-append; this is acceptable for an auto space.)

**Library space (split-on-demand).** The rail is the file tree (today's
`LibraryTree`). On tree-click:
- active tile is a `file` surface → `setActiveTileParams({path})` (re-point),
  **guarded**: if the outgoing path is dirty and no other tile shows it, the
  surface shows an in-UI two-step confirm before switching.
- no file tile / active tile is not a file → `openSurface('file', {path})`.
- **Split** button in the `FileSurface` header → `splitActive()` (A│A); re-point
  either pane via the tree.

**File buffers.** `filesStore` (`src/lib/stores/files.svelte.ts`) holds
`Map<path, {content, savedContent}>` keyed by **path** and shared across all
tiles showing that path → two tiles on one file stay in sync, one Save, one
dirty state. `dirty(path)`, `save(path)`, `load(path)`, `release(path)` (drop
buffer when no tile references it). The tree's dirty-dot reflects any open dirty
path. Replaces the single-buffer model in today's `libraryStore`.

**Details side pane.** In the Library space, `SidePane` reflects the active
tile's file (`layout.activeId` → binding → path → entry metadata), with the
existing Copy-reference footer.

**Active tile / focus routing.** Clicking a tile sets `activeId` (today's
behavior) **and** moves DOM focus into that tile's input target (terminal or
textarea); opening a surface focuses the new tile. This is explicit so keyboard
input always routes to the visibly-active tile.

**Launcher (Cmd+K).** Evolved `SpacesOverlay`, three sections: **Spaces**
(switch ●/○, + New, rename, save), **Open** (New session → the existing
`NewSessionDialog`, which on success opens a session tile; Open file → a
lightweight file picker reading the library tree, opens a file tile into the
active space even when no tree rail is present; Messages → opens the messages
surface), **Settings** (opens the Settings modal).

**Legacy routes.** Navigation moves from routes to spaces. `/` hosts the shell;
`/library`, `/messages`, `/settings` redirect to the matching space / open the
matching surface or modal; `/sessions/[id]` ensures that session's tile exists in
the Sessions space and focuses it (deep-link back-compat).

## Persistence (adapter seam)

`src/lib/shell/workspace-persistence.ts` defines:

```ts
interface WorkspaceSnapshot {
  version: number;            // schema version; bumped on shape change
  activeId: string;
  spaces: Array<{
    id: string; name: string;
    layout: ReturnType<TileLayout['serialize']>;
    bindings: Array<{ id: string; kind: string; params: object }>;
    sideOpen?: boolean; sideWidth?: number;
    dismissed?: string[];     // auto space only
  }>;
}

interface WorkspacePersistence {
  load(): WorkspaceSnapshot | null;
  save(snapshot: WorkspaceSnapshot): void;
}
```

Default `LocalStoragePersistence` (single key, e.g. `legend:workspace`). The
store reads/writes only through this interface; a future `SqlitePersistence`
(synced) is a drop-in.

**Tolerant load** (robustness gap #3): on `load`, if `version` mismatches, reset
to seeded defaults. Drop any binding whose `kind` is not in `SURFACES`. Keep
bindings whose entity may be absent (a `file` path that no longer exists, a
`session` not currently live) — the surface renders a graceful "missing /
unavailable" state and offers to close the tile; a dead tile never crashes the
space. Sessions are **not** persisted as bindings in the auto space — that space
repopulates from live data on load; only its `dismissed` set persists.

What persists: spaces (name, layout snapshot, manual bindings), active space,
per-space side open/width, auto-space dismissals. What does not: `draggingId`,
ghost state, live session tiles, file buffers (lazy-loaded on tile render).

## Component & file structure

**New — windowing core:**
- `src/lib/shell/tiling.svelte.ts` — `TileLayout` + `computeRects`.
- `src/lib/components/shell/TileGrid.svelte` — flat positioned grid view.
- `src/lib/shell/surfaces.ts` — surface registry.
- `src/lib/shell/workspace.svelte.ts` — `workspaceStore` + auto-sessions driver.
- `src/lib/shell/workspace-persistence.ts` — adapter interface + localStorage impl.

**New — surfaces & modal:**
- `src/lib/components/surfaces/SessionSurface.svelte` — wraps `SessionPane`.
- `src/lib/components/surfaces/FileSurface.svelte` — file editor pane (header:
  breadcrumb + Unsaved + Save + split + focus + close; body: textarea bound to
  `filesStore`; unsaved guard).
- `src/lib/components/surfaces/MessagesSurface.svelte` — wraps `MessagesPanel`.
- `src/lib/components/shell/ModalHost.svelte`, `Modal.svelte`.
- `src/lib/stores/files.svelte.ts` — `filesStore` (path-keyed buffers).

**Modified:**
- `src/lib/components/shell/LegendShell.svelte` — render the active space via
  `WorkbenchLayout`(space.rail → rail, `TileGrid` over `space.layout` → primary,
  space.side → side); mount `ModalHost`.
- `src/lib/components/shell/SpacesOverlay.svelte` → the launcher (sections above).
- `src/lib/shell/watchset.svelte.ts` — generic half becomes `TileLayout`;
  session-specific half becomes the auto driver in `workspaceStore`. File
  removed once callers migrate.
- `src/lib/components/sessions/WatchSetGrid.svelte` — removed; the Sessions space
  uses `TileGrid` + `SessionSurface` directly.
- `src/routes/+page.svelte` and the `/library`, `/messages`, `/settings`,
  `/sessions/[id]` routes — collapse to the shell + redirects/deep-links above.
- `src/lib/shell/views.ts` — replaced by the spaces registry (seeded defaults).
- `src/routes/settings/+page.svelte` content → the Settings modal.

**Untouched (reused as-is):** `WorkbenchLayout`, `SidePane`/`SidePaneSection`/
`SidePaneField`, `SessionPane`, `LibraryTree`, `MessagesPanel`, `IconButton`,
`Popover`, `MenuItem`, `ConfirmButton`, `Surface`, all design-system tokens.

## Migration order (task spine) + parity checkpoint

1. Extract `TileLayout` + `computeRects` (with Vitest unit tests). Sessions still
   on the old grid.
2. Build flat `TileGrid`; point the existing Sessions grid at it via a
   `TileLayout` instance (interim) so Sessions stays green.
3. Surface registry + `workspaceStore` + persistence adapter + auto-sessions
   driver.
4. Seed Sessions + Library spaces; render via `LegendShell` + `WorkbenchLayout`.
   **➤ PARITY CHECKPOINT:** Sessions and Library must look and behave exactly as
   they do today before proceeding. Stop and verify here.
5. `FileSurface` + `filesStore` + Library tree re-pointing + split-on-demand
   (replaces `libraryStore`'s single-buffer editor).
6. `MessagesSurface`; `ModalHost` + Settings modal; launcher (evolve
   `SpacesOverlay`); legacy-route redirects.
7. Persistence wire-up (save/restore spaces; tolerant load).
8. Docs: VISION.md, ARCHITECTURE.md, DESIGN_SYSTEM.md.

## Testing

- **Vitest** (new dev dependency; integrates with the present Vite) for the pure
  logic: `TileLayout` (add/remove/dropRelative in all four directions, resize
  weight math, focus, serialize/restore) and `computeRects` (rect distribution,
  seams, single tile, deep splits), and the auto-sessions reconcile (add/drop/
  dismiss/cap). *Adding Vitest is a decision flagged for review — see below.*
- `cd frontend && bun run check` — svelte-check 0 errors / 0 warnings.
- `cd frontend && bun run build` — static SPA builds.
- **Manual click-through:** Sessions parity (auto-tile, drag, resize, zoom,
  evict) with **no terminal repaint on re-tile**; Library split-on-demand +
  unsaved guard; open mixed surfaces (file beside session) into a custom space;
  save / switch / reload a space (tolerant load with a deleted file); Messages
  surface; Settings modal; Tauri load (no `window` access at module top level).

## Risks & how they're handled

- **Terminal survival on re-tile** → flat positioned rendering; components mount
  once, never reparent. The core reason for the `TileGrid` design.
- **Blast radius on the just-shipped shell** → phased order with a hard parity
  checkpoint at step 4 before the launcher/modal/route rework.
- **Stale persisted state** → schema `version` + tolerant load (drop unknown
  kinds, graceful missing-entity tiles).
- **Keyboard focus across many tiles** → explicit focus routing on click/open.
- **File-open without a tree rail** → launcher file picker.
- **Two tiles on one file** → shared path-keyed buffer (no divergence; selection/
  scroll per textarea differ, acceptable).
- **Same session in two spaces** → two xterms on one PTY channel (backend already
  multiplexes reattach); acceptable, low-frequency.

## Documentation updates (same cycle)

- **VISION.md** — name tiling as the windowing core; surfaces as the concrete
  form of "UI panels are extension points"; spaces as user- (later agent-)
  arrangeable workspaces. (Vision changes first, per its own preamble.)
- **ARCHITECTURE.md** — the windowing core, surface registry, space/workspace
  model, persistence adapter seam, modal layer; note the auto-sessions driver as
  the relocated watch-set logic.
- **DESIGN_SYSTEM.md** — `TileGrid` and the space-frame composition as
  first-class shell primitives alongside `WorkbenchLayout`/`SidePane`.

## Open decision for review

- **Add Vitest?** Recommended: the windowing core is non-trivial pure logic
  (tree ops, rect math, reconcile) that warrants real unit tests, and Vitest
  rides the existing Vite with negligible setup. Alternative: rely on
  svelte-check + manual click-through and skip new test infra. Flagged because it
  adds a dev dependency and a `test` script.
