# Pane header unification

**Date:** 2026-06-22
**Status:** Approved design

## Problem

Each window surface in the tiling workspace hand-rolls its own header `<div>`. This has caused drift:

- **SessionPane** ([`sessions/SessionPane.svelte`](../../../frontend/src/lib/components/sessions/SessionPane.svelte)) — the canonical, modern header: drag handle, `expand`/`shrink` maximize, `close`, all `box={24} size={14}`.
- **FileSurface** ([`library/FileSurface.svelte`](../../../frontend/src/lib/components/library/FileSurface.svelte)) — older header: uses the `eye` icon for focus, `box={20}` buttons, a different action order.
- **MessagesSurface** ([`surfaces/MessagesSurface.svelte`](../../../frontend/src/lib/components/surfaces/MessagesSurface.svelte)) — **no window header at all**, just an inner `<h1>Messages</h1>`. It cannot be closed, dragged, or maximized from its own pane.

We want every window to share the same header icons and styles, and to guarantee a basic set of actions, while still allowing per-surface extras.

## Goal

One generic header primitive used by all surfaces. Universal baseline = **drag · maximize/restore · close**. Surface-specific actions (Save, Split, Details, More, transport toggle, status meta) layer on top.

## Design

### New primitive: `PaneHeader.svelte`

Location: `frontend/src/lib/components/shell/PaneHeader.svelte`. A dumb shell primitive — no store imports, consistent with the other `shell/` primitives.

**Props**

```ts
{
  tileId: string;                       // the grid tile this pane occupies
  layout: TileLayout;                   // owning space's layout (for active/focus state)
  grab?: (e: PointerEvent) => void;     // grid drag starter
  onClose: () => void;                  // close handler (surface decides semantics)
  title: Snippet;                       // left, draggable identity region
  meta?: Snippet;                       // loosely-spaced status zone (badges, time, toggles, Save)
  actions?: Snippet;                    // surface icon buttons, joined tight with maximize/close
}
```

Two trailing snippets, because surfaces carry two visually distinct kinds of trailing
content: **meta** (status badges, relative time, the transport toggle, a Save button —
rendered as direct children of the header's `gap-2` row, matching the spacing the old
SessionPane header already used for badge/time/transport) and **actions** (icon buttons —
`more`, `panel-right`, `columns` — that read as one tight `gap-0.5` cluster with the
universal maximize/close pair). Keeping them separate is what makes Files' buttons stop
being loosely scattered and match Sessions' tight cluster.

**Derived from `layout` + `tileId`:** `active` (`layout.activeId === tileId`), `focusedMode` (`layout.focusedId === tileId`), `dragging` (`layout.draggingId === tileId`).

**Responsibilities (the generic parts):**

- **Active tint** — header background switches on `active` to the existing
  `color-mix(in oklab, var(--accent) 7%, var(--bg-shell))` wash, else `var(--bg-shell)`.
- **Drag** — the `title` region is the grab handle: `onpointerdown → grab?.()`, `role="button"`, `cursor-grab`/`cursor-grabbing`, `title="Drag to re-tile"`.
- **Maximize/restore** — `expand` icon (or `shrink` when `focusedMode`) toggling
  `layout.focus(tileId)` / `layout.restore()`, `tone="accent"`, `active={focusedMode}`.
- **Close** — `close` icon → `onClose`.

**Layout:** a single `h-[var(--h-bar)]` flex row (`gap-2`):

```
[ draggable title (min-w-0 flex-1) ] [ meta? ] [ actions? ⤢ maximize ✕ close ]
                                       loose      └──── tight gap-0.5 ────┘
```

All header buttons use `IconButton` with `box={24} size={14}`. The `actions` snippet,
maximize, and close share one tight `gap-0.5` cluster at the far right; `meta` sits just
before it as a normally-spaced group.

### Per-surface changes

| Surface | `title` | `meta` | `actions` | Net effect |
|---|---|---|---|---|
| **SessionPane** | StatusDot · name (inline-editable) · identity tag · summary | badge · time · transport toggle · `VDiv` | `more` menu · `panel-right` details | No visible change — moves the header boilerplate into `PaneHeader`. Icons already canonical. |
| **FileSurface** | "Library" · breadcrumbs | "Unsaved" · Save | `columns` split · `panel-right` details · `more` menu | **Fixes old icons**: `eye` → `expand`/`shrink`, `box={20}` → `24`, buttons tighten into one cluster, maximize moves next to close. |
| **MessagesSurface** | `message` icon · "Messages" · message count | _(none)_ | _(none — baseline only)_ | **Gains a header**: drag, maximize, close. Inner `<h1>` removed; pulls `layout`/`onClose` via `workspaceStore` like the other two. |

MessagesSurface also adopts the standard surface-root treatment the other two already have: outer container `onpointerdown → layout.setActive(tileId)` and `opacity: 0.45` while `dragging`.

### Out of scope / unchanged

- The surface registry contract (`{ tileId, params, grab }`) — already flows to every surface.
- Workspace logic: `splitActive`, `closeTile`, `focus`/`restore`, dedupe/persistence.
- `SidePane` — the Details panel **body** stays per-surface; only the header toggle is unified.
- The SessionSurface "session unavailable" fallback (an error state with no pane chrome).

## Verification

- `cd frontend && bun run check` (svelte-check) passes.
- Live browser check: each of the three surfaces renders the unified header; Messages can now be dragged, maximized/restored, and closed; Files shows `expand`/`shrink` instead of `eye`; active-tile tint and drag-to-retile still work.
