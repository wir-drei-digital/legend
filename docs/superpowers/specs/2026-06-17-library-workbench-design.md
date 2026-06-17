# Library Workbench — reusable three-pane layout + generic side pane

- **Date:** 2026-06-17
- **Status:** Draft (awaiting review)
- **Scope:** Frontend only (`frontend/`). No backend changes.

## Problem

The Library view (`/library`) is a functional but unstyled placeholder: an `aside`
file tree plus a `<textarea>`, all still using pre-design-system shadcn classes
(`border`, `text-muted-foreground`, `bg-accent`) rather than the Legend tokens.
We want to bring it up to the design system, matching the provided mock (a
file-tree rail, a primary editor, and a right-hand metadata pane), and — more
importantly — extract the layout into reusable primitives so other contexts
(e.g. an expanded chat view) can adopt the same structure.

Two reusable units come out of this:

1. A **three-region layout** (rail | primary | side) that owns *arrangement only*.
2. A **generic side pane** (header + sectioned body + footer) for metadata/detail.

## Goals

- Ship a polished Library view that matches the mock's structure and uses Legend
  design tokens throughout.
- Extract a generic `WorkbenchLayout` (rail / primary / side) and a generic
  `SidePane`, decoupled from each other so either can be reused independently.
- Wire everything to the **real** file API that already exists
  (`listTree`/`readFile`/`writeFile`/`deleteFile`). Show only metadata that has
  real backing today.

## Non-goals

- No backend work. No version history, agent-usage ("fed to N agents"), sync
  state, or authorship tracking — none of these have backing data, so they are
  **not shown** (see "Honesty rule"). The generic components are built so these
  sections *can* be added later without rework.
- No syntax highlighting / markdown preview. The editor stays a styled
  monospace `<textarea>` (the mock's coloring is illustrative).
- No changes to the global `StatusBar` (the bottom agent-activity strip / budget
  meter is existing shell chrome, unrelated to this feature).
- No migration of the Sessions view onto `WorkbenchLayout` (it keeps using the
  shell `bench` slot). `WorkbenchLayout`'s visual defaults are chosen so a future
  unification is possible, but that is out of scope here.

## Architecture

### Composition model

The app shell (`LegendShell`) keeps rendering `TopBar` + page `children` +
`StatusBar`. The Library page declares **no shell `bench`** — instead its page
body (`children`) is a `WorkbenchLayout` that owns all three regions. This keeps
the "three panes" concept in one place (matching how the feature was described).

Library view-state lives in a small **`libraryStore`** (a runes `.svelte.ts`
singleton, mirroring `sessionsStore`). This is required because the **New file**
action is a per-view **toolbar** rendered by the shell's `TopBar` — *outside* the
page's component tree — so it can't reach page-local handlers. `libraryStore`
gives the shell-rendered toolbar, the rail, the editor, and the side pane one
shared source of truth, exactly as `sessionsStore`/`watchSet` coordinate the
Sessions bench/toolbar/grid. `WorkbenchLayout` and `SidePane` stay generic and
state-agnostic; only the Library-specific pieces read the store.

```
TopBar  [ Library ▾ ]  …………………………………  [ + New file ]   ← view toolbar
┌───────────────────────────────────────────────────────────┐
│ WorkbenchLayout (page children)                            │
│ ┌────────┬───────────────────────────┬──────────────────┐ │
│ │  rail  │  primary                  ║  side            │ │
│ │ (tree) │  (editor)                 ║  (SidePane)      │ │
│ └────────┴───────────────────────────┴──────────────────┘ │
└───────────────────────────────────────────────────────────┘
StatusBar
                                       ↑ draggable resize seam + collapse toggle
```

### `WorkbenchLayout.svelte` (generic, `src/lib/components/shell/`)

Owns arrangement only. Knows nothing about files or chat.

**Props / snippets:**
- `rail: Snippet` — left region content.
- `primary: Snippet` — center region content.
- `side: Snippet` — right region content (hosts *whatever* is passed; typically a
  `SidePane`, but not coupled to it).
- `sideOpen = $bindable(true)` — collapse state for the side region.
- `sideWidth = $bindable(320)` — pixel width of the side region (default 320px,
  clamped 240px–40vw on resize).
- `railWidth = 178` — fixed rail width (matches `SessionBench` for consistency).

**Behavior:**
- Layout: a flex row — fixed-width rail (`border-r border-hair bg-shell`),
  flex-1 primary (`bg-app`), and a right region of `sideWidth` px when `sideOpen`.
- **Resize seam** between primary and side: a 1px `bg-hair` divider with a wider
  invisible pointer target, dragged to set `sideWidth` (clamped to a min, e.g.
  240px, and a max fraction of the viewport). Reuses the pointer-drag pattern
  already present in `WatchSetGrid` (`pointerdown`/`pointermove`/`pointerup`,
  `userSelect: none` during drag), extracted clean.
- When `sideOpen` is false the side region and seam are not rendered.
- **Persistence:** `sideWidth` and `sideOpen` persist to `localStorage` under a
  caller-supplied `storageKey` prop (e.g. `legend:library:side`). Reads are
  guarded for SSR-safety (`ssr = false` already, but guard `window` anyway).

### `SidePane.svelte` (generic, `src/lib/components/shell/`)

A presentational detail/metadata pane. Driven by props + snippets.

**Props / snippets:**
- `title: string`, `icon?: IconName` — header.
- `onClose?: () => void` — renders a close/collapse affordance when provided.
- `onPin?: () => void`, `pinned?: boolean` — optional pin action (generic
  capability; Library does not pass it — see Honesty rule).
- `actions?: Snippet` — optional overflow/extra header actions.
- `children: Snippet` — scrollable body.
- `footer?: Snippet` — optional pinned footer (e.g. a "Copy reference" button).

**Subcomponents** (same file or co-located, used by the body):
- `SidePaneSection` — a labeled block: a `font-mono` uppercase tracked label
  (matching the mock's `SOURCE` / `STATE` / `VERSIONS` headers) + slotted body.
- `SidePaneField` — a label/value row for simple metadata.

These two helpers *are* used by Library, so they are built now. No speculative
`AvatarStack` / `VersionList` (YAGNI) — `SidePaneSection` already makes adding
them later trivial.

### Library page (`src/routes/library/+page.svelte`, rewritten)

Shared view state lives in `libraryStore`: `tree`, `entries` (flat list, for
metadata lookup), `selected`, `content`, `savedContent`, `error`, `loaded`, with
derived `dirty` (`content !== savedContent`) and `selectedEntry`. Actions:
`refresh()`, `open(path)`, `save()`, `create(path)`, `remove()`. The existing
open/save/create/delete logic is preserved (it already handles the
unsaved-changes guard and the Tauri `confirm` no-op correctly); it moves from the
page into the store. The page keeps only ephemeral UI flags (two-step confirm,
new-file popover open) as local `$state`.

Composition:

```
<WorkbenchLayout storageKey="legend:library:side" bind:sideOpen bind:sideWidth>
  {#snippet rail()}     <LibraryTree …> + rail header (filter)   {/snippet}
  {#snippet primary()}  editor (breadcrumb + textarea)            {/snippet}
  {#snippet side()}     <SidePane title="Details" …>             {/snippet}
</WorkbenchLayout>
```

#### Rail (`LibraryTree.svelte`, restyled)
- Restyle to Legend tokens (`text-ink-*`, `hover:bg-[var(--hover-tint)]`, accent
  spine/`bg-[var(--accent-soft)]` for the selected file — mirroring
  `SessionBench` row treatment) and the `Icon` set (`folder`, plus a file glyph).
- Rail header mirrors `SessionBench`: a title ("Explorer"), the file count, and a
  **client-side filter** input toggled by a search button. Filtering matches node
  names; parent folders of matches stay visible.
- **Dirty dot**: the currently-open-but-unsaved file shows a small accent dot
  (the only per-row badge with real backing).

#### Primary editor
- Header row: a **breadcrumb** built from the selected path
  (`Library / Documents / brand-voice.md`), an `Unsaved` indicator when dirty, a
  **Save** button (`⌘S`, already wired), a **toggle-side-pane** button (the mock's
  split-view icon → flips `sideOpen`), and a `⋯` menu containing **Delete**
  (two-step in-UI confirm; no `window.confirm`).
- Body: the existing monospace `<textarea>` restyled (`bg-app`, `text-ink-1`,
  Legend mono font), preserving `⌘S` to save. Empty state when nothing selected.

#### Side pane (`SidePane` titled "Details")
Only real fields, in `SidePaneSection`s:
- **Identity:** file name + icon, a type/size line ("Document · 4 KB" style, from
  `type` + `size`).
- **Details:** modified time (`mtime`, via the existing `relativeTime` helper) and
  the full library path.
- **Footer:** a **Copy reference** button — copies the file's library path to the
  clipboard (genuinely useful given the `[[…]]`/library-reference convention).

`size`/`mtime` come from the tree entry (`LibraryEntry` already carries them); the
selected entry is looked up from the flat list (kept alongside the tree).

#### Toolbar (`LibraryToolbar.svelte`, registered as the view's `toolbar`)
- A **New file** button (top bar, like `SessionsToolbar`'s "New session"). Opens an
  in-UI new-file affordance (small popover/input — reusing the existing
  create-by-path flow; no `window.prompt`). On create, refresh + open the file.
- Update `views.ts`: the `library` entry gains `toolbar: LibraryToolbar` and drops
  the `sub` text (the toolbar now carries the primary action).

### Honesty rule — shown vs omitted

**Shown (real backing):** file tree; open/edit/save/create/delete; dirty dot;
rail filter; breadcrumb; name/type/size/modified/path; Copy reference; New file.

**Omitted (no backing data):** tree-row agent letter-chips & error/lock badges;
`Source / Authored by`, `State / synced`, `Fed to N agents`, `Versions` sections;
the history (clock) icon; the pin action. The generic components *support* these
(via `SidePaneSection` and `SidePane`'s `onPin`), so they can be added when the
data exists — they are simply not rendered now.

## Reuse: expanded chat view (future)

The expanded chat view will reuse **`SidePane`** directly (its own sections), and
may reuse **`WorkbenchLayout`** for a list | conversation | detail arrangement.
Neither component knows about Library, so no Library code is pulled in.

## Testing

- `cd frontend && bun run check` (svelte-check) must pass.
- `cd frontend && bun run build` must succeed (static SPA).
- Manual: open/edit/save/create/delete a file; toggle + drag the side pane and
  reload to confirm width/open persist; verify the unsaved-changes guard still
  fires; confirm the Tauri build still loads (no `window` access at module top).

## File plan

**New**
- `src/lib/stores/library.svelte.ts` — `libraryStore` (runes singleton; view
  state + file CRUD actions).
- `src/lib/components/shell/WorkbenchLayout.svelte`
- `src/lib/components/shell/SidePane.svelte` (+ `SidePaneSection`, `SidePaneField`)
- `src/lib/components/library/LibraryToolbar.svelte` (per-view toolbar, like
  `SessionsToolbar`)

**Modified**
- `src/routes/library/+page.svelte` — rewritten to compose the above.
- `src/lib/components/LibraryTree.svelte` — restyled to Legend tokens + dirty dot
  + filter support. (May move to `src/lib/components/library/`.)
- `src/lib/shell/views.ts` — `library` entry gains `toolbar`, drops `sub`.
- Possibly `src/lib/components/shell/Icon.svelte` — add a file glyph + a
  side-pane/split-toggle glyph if not expressible with the current set.
