# Legend — Design System

Canonical reference for the frontend design system. The raw tokens live in
[`frontend/src/routes/layout.css`](../frontend/src/routes/layout.css); the shell
primitives live in `frontend/src/lib/components/shell/`. This doc is the source of
truth for what those tokens *mean* and which primitive to reach for — keep it in
sync when either layer changes.

The aesthetic: **dark only**, a near-black violet surface ramp, a single themeable
**amber / ember accent**, dense rows, tabular figures. The accent is a warm orange
(~55°) set near-complementary to the cool violet-black surfaces — deliberately off the
teal/indigo/violet "AI dark tool" default, and an instrument-light nod to the terminal
heritage. It's two-tone: a deep ember fill (white text stays legible) + a bright amber
highlight for rings/active/brand text. Two layers sit between feature code and
Tailwind/shadcn:

1. **Token layer** (`layout.css`) — CSS custom properties + Tailwind `@theme`
   utilities. The raw `--bg-*` / `--text-*` / `--accent*` tokens are the source of
   truth; the shadcn semantic variables (`--background`, `--primary`, …) are *mapped
   onto them* so every shadcn component inherits the palette for free.
2. **Primitive layer** (`components/shell/`) — small Svelte 5 components that bake
   the tokens into the recurring shapes (icon buttons, surfaces, popovers, menu rows,
   side panes, the tiling grid, the source dock). Feature code composes these, not raw classes.

---

## Palette

Dark only. All values are literal from `layout.css`.

### Surfaces — void → shell → app → panel/raised → inset

| Token | Value | Utility | Use |
| --- | --- | --- | --- |
| `--bg-void` | `#08070d` | `bg-void` | the deepest backdrop (desktop void behind chrome) |
| `--bg-shell` | `#0c0a13` | `bg-shell` | chrome: rails, side panes, top/status bars (the `<body>` bg) |
| `--bg-app` | `#100d1a` | `bg-app` | the primary work area (window content) |
| `--bg-panel` | `#151022` | `bg-panel` | raised panels, cards, popover surfaces (shadcn `--card`/`--popover`) |
| `--bg-raised` | `#1b1530` | `bg-raised` | the next step up: hover/selection fills, secondary buttons |
| `--bg-inset` | `#0e0b17` | `bg-inset` | recessed wells (shadcn `--muted`) |

### Hairlines

| Token | Value | Utility | Use |
| --- | --- | --- | --- |
| `--border` | `rgba(255,255,255,0.07)` | `border-hair` | default 1px separators |
| `--border-strong` | `rgba(255,255,255,0.13)` | `border-hair-strong` | emphasized edges (floating surfaces, inputs) |

### Text ramp

| Token | Value | Utility | Use |
| --- | --- | --- | --- |
| `--text-1` | `#edeaf7` | `text-ink-1` | primary text |
| `--text-2` | `#a49ebc` | `text-ink-2` | secondary text, titles in chrome |
| `--text-3` | `#83849b` | `text-ink-3` | tertiary: labels, captions, idle icons (AA on 9px labels) |

### Accent (themeable)

Every selection/active/focus state derives from these. **Re-theming = changing
`--accent` (+ its `-hi`/`-soft`).**

| Token | Value | Utility | Use |
| --- | --- | --- | --- |
| `--accent` | `#b75400` | `text-brand` / `bg-brand` / shadcn `--primary` | brand fill, primary buttons (deep ember; #fff text 4.90:1) |
| `--accent-hi` | `#fea03f` | `text-brand-hi` | brighter accent: active icons, focus ring (`--ring`) — 9.6:1 on shell |
| `--accent-soft` | `rgba(254,160,63,0.15)` | `bg-brand-soft` | tinted accent backgrounds, pulse rings |
| `--accent-contrast` | `#ffffff` | (via `--primary-foreground`) | text/icon on an accent fill |

Note: shadcn's own `--accent` is its **neutral hover/selection token**, mapped to
`--bg-raised` in `@theme` — it is *not* the brand accent. The brand accent is
shadcn's `--primary`.

### Status

| Token | Value | Utility |
| --- | --- | --- |
| `--green` | `#4bdba0` | `text-ok` / `bg-ok` (shadcn `--chart-5`) |
| `--amber` | `#e9c944` | `text-warn` / `bg-warn` (shadcn `--chart-4`) |
| `--red` | `#fa5153` | `text-bad` / `bg-bad` (shadcn `--destructive`) |

### Agent identity ramp

Each distinct from the accent and from each other.

| Token | Value | Utility | Identity |
| --- | --- | --- | --- |
| `--claude` | `#e0745c` | `text-claude` / `bg-claude` | Claude Code |
| `--hermes` | `#5b9aed` | `text-hermes` / `bg-hermes` | Hermes |
| `--openclaw` | `#0dc1d0` | `text-openclaw` / `bg-openclaw` | OpenClaw (cyan — moved off error-red) |
| `--legend` | `#fea03f` | `text-legend` / `bg-legend` | Legend itself (= accent-hi) |

### Neutral hover tint

| Token | Value | Use |
| --- | --- | --- |
| `--hover-tint` | `rgba(160,170,220,0.06)` | the standard neutral hover fill (`hover:bg-[var(--hover-tint)]`). **Intentionally not derived from the accent** so a loud accent never bleeds into every surface. |

---

## Type scale

Every UI font-size is one of these five — defined as `@theme` utilities, so they
appear as `text-micro … text-title`. No ad-hoc `text-[Npx]` in feature code.

| Utility | px | Use |
| --- | --- | --- |
| `text-micro` | 9px | uppercase section labels, the tiniest captions |
| `text-meta` | 10.5px | metadata, counts, secondary annotations |
| `text-ui` | 11.5px | the default UI body — list rows, menu items, pane fields |
| `text-body` | 12.5px | comfortable body copy |
| `text-title` | 13px | titles / the largest in-chrome text |

Fonts: Geist Variable throughout. Both `--font-sans` and `--font-mono` resolve to
Geist Variable — the UI uses one proportional family everywhere. `.font-mono` no
longer changes the typeface; it only carries `font-variant-numeric: tabular-nums`
so counts/ids line up. True monospace is reserved for the terminal, which sets
Geist Mono Variable directly (column alignment / TUIs need it).

When migrating a stray pixel size, map: `9, 9.5 → text-micro`;
`10, 10.5, 11 → text-meta`; `11.5 → text-ui`; `12, 12.5 → text-body`;
`13 → text-title`.

---

## Elevation

Three named float levels (`@theme` shadows → `shadow-pop` / `shadow-overlay` /
`shadow-drag`).

| Utility | Value | Use |
| --- | --- | --- |
| `shadow-pop` | `0 18px 44px -12px rgb(0 0 0 / 0.7)` | menus, popovers |
| `shadow-overlay` | `0 24px 60px -12px rgb(0 0 0 / 0.7)` | large floating panels |
| `shadow-drag` | `0 12px 30px -8px rgb(0 0 0 / 0.7)` | drag ghosts |

---

## Control heights

Dense, fixed. Applied as `h-[var(--h-bar)]` / `h-[var(--h-row)]`.

| Token | Value | Use |
| --- | --- | --- |
| `--h-bar` | 32px | in-body section/toolbar header rows (e.g. the `SidePane` header) |
| `--h-row` | 26px | dense list rows + menu items (e.g. `MenuItem`) |

---

## Radii

Base `--radius` is `0.6875rem` (11px); shadcn derives the rest in `@theme`.

| Utility | Computed | Use |
| --- | --- | --- |
| `rounded-sm` | `--radius * 0.55` (~6px) | small chips, tight controls |
| `rounded-md` | `--radius * 0.78` (~9px) | buttons, icon buttons |
| `rounded-lg` | `--radius` (11px) | the standard panel/card radius |
| `rounded-xl` | `--radius * 1.35` (~15px) | larger panels |
| `rounded-2xl …4xl` | `--radius * 1.75 … 2.5` | progressively larger surfaces |

The window itself uses 16px (set on the Tauri/shell frame). `Surface` uses a literal
`rounded-[10px]` for floating menus.

---

## Theming model

- **Dark only, today.** The `.dark` class lives on `<html>` (`app.html`); the palette
  is re-declared under `.dark` so `dark:` utilities resolve to the same tokens.
  **There is no runtime theme switcher.**
- **Re-theme = swap `--accent`** (and its `--accent-hi` / `--accent-soft` partners).
  Because every active/selection/focus state derives from the accent and the shadcn
  semantics are mapped onto the raw tokens, changing the accent re-themes every active
  state app-wide.
- **Add a theme = a parallel token block under a class selector** (e.g. `.theme-x { … }`
  redeclaring the `--bg-*` / `--text-*` / `--accent*` tokens), then toggle that class on
  a root element. None of this exists yet — there is one (dark) theme and no switcher.
- The shadcn semantic mapping is the seam: feature code and shadcn components both read
  the *semantic* names, which point at the raw tokens, so the two layers stay in sync
  from one place.

---

## Primitive catalog

All in `frontend/src/lib/components/shell/`. Props are the real signatures; reach for
the primitive instead of re-deriving its classes.

### `IconButton`
Square, icon-only button with token-correct hover/active/disabled states.
- Props: `icon: IconName` (req), `size = 14`, `box = 24` (button px), `title?`,
  `onclick?(e)`, `active = false`, `tone: 'default' | 'accent' | 'danger' = 'default'`,
  `disabled = false`, `class?`.
- Use when: any icon-only affordance — toolbar actions, close/pin buttons, row controls.

### `Surface`
A rounded, hairline-bordered floating container with elevation. The visual shell of
menus/panels.
- Props: `elevation: 'pop' | 'overlay' = 'pop'`, `class?`, `children` (req).
- Use when: you need a free-standing floating surface but are positioning it yourself
  (not via `Popover`).

### `Popover`
A bindable, click-outside-dismiss floating layer built on `Surface`, with a backdrop and
a rise animation. The caller supplies position + width via `class`; the positioned
content is the `children`.
- Props: `open = $bindable(false)`, `class?` (position/width), `elevation: 'pop' | 'overlay' = 'pop'`,
  `onclose?()`, `children` (req).
- Use when: dropdown menus, context menus, any small dismissible overlay. Bind `open`
  to a local `$state` (replaces hand-rolled backdrops).

### `MenuItem`
A full-width, `--h-row`-tall menu row with optional leading icon and a danger tone.
- Props: `icon?: IconName`, `tone: 'default' | 'danger' = 'default'`, `onclick?()`,
  `disabled = false`, `children` (req).
- Use when: rows inside a `Popover`/menu surface.

### `ConfirmButton`
A two-step destructive `MenuItem`: first click arms (swaps to the confirm label), second
click fires. Built because `window.confirm` is a no-op in the Tauri webview.
- Props: `idleLabel: string` (req), `confirmLabel: string` (req), `onconfirm()` (req),
  `icon: IconName = 'trash'`.
- Use when: a destructive action inside a menu needs in-UI confirmation.

### `SectionLabel`
The uppercase mono micro-label (`text-micro`, `tracking-[0.14em]`, `text-ink-3`).
- Props: `class?`, `children` (req).
- Use when: labeling a group of fields/rows; the building block of `SidePaneSection`.

### `SidePane`
The full side-pane scaffold: a `--h-bar` header (icon + truncating title + optional
actions / pin / close), a scrolling body, an optional footer. Background `bg-shell`.
- Props: `title: string` (req), `icon?: IconName`, `onClose?()`, `onPin?()`,
  `pinned = false`, `actions?: Snippet`, `children: Snippet` (req), `footer?: Snippet`.
- Use when: any right-hand detail/inspector pane — including a tile's own in-window
  **Details** panel (`FileSurface`, `SessionPane` render a `SidePane` inside the tile,
  toggled from the tile header), not only a space-level inspector.

### `SidePaneSection`
A labeled section inside a `SidePane` body: a `SectionLabel` over its children, with the
standard gap.
- Props: `label: string` (req), `children` (req).

### `SidePaneField`
A label/value row inside a section — label left (`text-ink-3`), value right (truncating,
`text-ink-1`, `title` tooltip), `text-ui`.
- Props: `label: string` (req), `value: string` (req).

### `Dock`
The persistent left **source dock** — one shell-wide column rendering pluggable
`DockSource` sections (Sessions, Files) from the `DOCK_SOURCES` registry
(`$lib/shell/dock-sources.ts`). Each section is a collapsible group; the whole dock
collapses to a 36px icon rail. **Click** a dock item to open it into the active space;
**drag** it into the grid (pointer drag via the `dockDrag` shared state) for precise
placement. Open/collapsed state persists in `localStorage` (`legend:dock`).
- Props: none — it reads `DOCK_SOURCES` and owns its own collapse state.
- Use when: nowhere else — it's a singleton mounted once by `LegendShell` to the left of
  the `TileGrid`. Add a new source by registering a `DockSource`, not by editing `Dock`.
- Replaced the per-space `WorkbenchLayout` rail/primary/side split (retired with the dock,
  alongside `SessionBench` / `LibraryRail` / `LibrarySide`).

**In-list group headers** — a second-level collapse *inside* a Dock source (the
session list groups by working directory). The header is a `--h-row` button:
chevron + `folder` icon + uppercase `text-micro` label (`tracking-[0.08em]`,
`text-ink-3`) + a `font-mono text-micro` count, with the full path as the `title`.
Remote rows carry a `cloud` glyph before the harness tag.

### `TileGrid`
The windowing primitive: a tiling layout of *surfaces*. Renders each tile **once** in a
flat list and positions it with an absolute `transform`/`width`/`height` derived from the
layout tree (`layout.rects(W, H)`, host measured via `ResizeObserver`) — re-tiling,
splitting, resizing, and focus only change a tile's rect, **never reparent the node**, so a
live surface (e.g. an xterm/PTY view) is never remounted. Owns the resize seams, the
drag-to-re-tile (i3-style directional split) ghost + drop overlay.
- Props: `layout: TileLayout` (req), `tile: Snippet<[id, grab]>` (req — renders one tile),
  `empty?: Snippet` (shown when no tiles), `dragLabel?(id) → string`, `minColPx = 160`,
  `minRowPx = 90`.
- **Surface contract:** the `tile` snippet receives `(tileId, grab)` and renders the
  surface component for that tile, passing `{ tileId, params, grab }` — `params` resolved
  from the surface registry binding, `grab` the pointer handler that begins a drag from the
  surface's header. (`SurfaceDef.component` types this exactly.)
- Use when: a space needs an arrangeable, splittable grid of surfaces. The render-once +
  rect-from-tree contract is the rule: do not key tiles by position or remount on re-tile.

### Space-frame composition
Every *space* is now the **same uniform frame**: the persistent `Dock` on the left, a single
`TileGrid` filling the rest (`bg-app`). `LegendShell` renders this one shape for every space —
Sessions, Library, and custom alike differ only in their tile contents, not their chrome. The
old per-space frames (the `SessionBench` aside, the `WorkbenchLayout` rail/side around Library)
were retired with the dock; there is no longer a frame to pick. The grid supplies its own
`empty` snippet ("drag a file or session from the dock").

---

## Token-discipline rule

**Feature code uses Legend tokens + shell primitives. It never uses raw shadcn neutral
classes, ad-hoc hex, or ad-hoc `text-[Npx]`.** Concretely, outside
`src/lib/components/ui/`:

- No raw shadcn neutral classes — `text-muted-foreground`, `bg-muted`, `bg-background`,
  `bg-accent`, `text-foreground`, `bg-card`, `bg-popover`, `text-accent-foreground`.
  Use the Legend utilities (`text-ink-*`, `bg-shell/app/panel/raised/inset`,
  `border-hair*`) or a shell primitive.
- No ad-hoc hex colors — use a palette token.
- No ad-hoc pixel font sizes (`text-[Npx]`) — use the type scale (`text-micro … text-title`).

`src/lib/components/ui/` (the shadcn primitives) is the **only** place shadcn semantic
classes appear; those components inherit the palette via the semantic mapping and are
out of scope for this rule. The two grep gates that enforce it (one for neutral classes,
one for `text-[Npx]`) live in the design-system hardening task and must stay empty
outside `ui/`.
