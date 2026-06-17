# Design System Hardening — tokens, primitives, consistency

- **Date:** 2026-06-17
- **Status:** Draft (awaiting review)
- **Scope:** Frontend only (`frontend/`). No backend changes.

## Problem

Legend has a real design system — a token ramp in `src/routes/layout.css`, shadcn
semantic vars mapped onto those tokens (so `ui/` primitives inherit the palette),
and a themeable accent. The newer views (Sessions, Library, the `shell/`) use it
consistently. But an audit found four gaps that undercut "reusable, consistent,
themeable, flexible":

1. **Consistency drift.** Five surfaces never moved onto the system and still use
   raw shadcn defaults (`text-sm`/`rounded-md`/`bg-muted`/`text-muted-foreground`):
   `routes/messages/+page.svelte`, `routes/settings/+page.svelte`,
   `NewSessionDialog.svelte`, `MessageComposer.svelte`, `MessagesPanel.svelte`.
2. **Reuse gaps.** Recurring patterns are copy-pasted inline rather than extracted:
   the popover/menu surface (4×), the icon-button (~everywhere), the mono section
   label, the two-step destructive confirm.
3. **Theming/flexibility gaps.** Elevation/shadows are ad-hoc inline values (three
   variants); the dense type scale and control heights are repeated magic numbers
   (`text-[11.5px]`, `h-[26px]`, `h-[29px]`…) rather than named tokens.
4. **No consolidated docs.** Tokens are documented inline in `layout.css`; there is
   no design-system reference and the component conventions are implicit.

**Constraint note:** the project is early — **backwards compatibility is not a
concern.** Optimize for consistency and clean, reusable code, including rewriting
working views and snapping off-scale values onto the canonical scale.

## Goals

- Every visual decision is a token (palette, type scale, elevation, control
  heights, radii). The full token set is the theming contract.
- The recurring UI patterns exist once, as shell primitives, and are adopted
  across the app.
- All five laggard surfaces match the Legend dense aesthetic.
- A single canonical design-system reference doc, plus pointers from
  `ARCHITECTURE.md` and `CLAUDE.md`.

## Non-goals

- **No light mode and no runtime theme switcher.** Dark-only stays; the accent is
  swappable at design time and the docs explain how to add a theme later. (YAGNI.)
- **No changes to the shadcn `ui/` primitives' internals.** They already inherit
  the palette through the semantic-var mapping; that mapping is the intended
  theming seam and stays. The `ui/` layer is the *only* place shadcn semantic
  classes (`bg-primary`, `text-muted-foreground`, …) legitimately appear.
- No backend changes.

## Design

### 1. Token formalization (`src/routes/layout.css`)

**Type scale** — collapse the ~9 ad-hoc sizes into a named 5-step scale, exposed
via Tailwind v4 `@theme` (`--text-<name>` → `text-<name>` utility):

| token        | px     | use                                  |
|--------------|--------|--------------------------------------|
| `text-micro` | 9      | mono caps labels, tiny badges        |
| `text-meta`  | 10.5   | counts, timestamps, secondary mono   |
| `text-ui`    | 11.5   | the workhorse UI text                |
| `text-body`  | 12.5   | titles, emphasis, file names         |
| `text-title` | 13     | view titles, brand, page headings    |

Migration mapping for existing values (snap to nearest; churn is acceptable):
`9,9.5 → micro` · `10,10.5,11 → meta`(11→10.5) · `11.5 → ui` · `12 → body`(12→12.5)
· `12.5 → body` · `13 → title`. Laggard shadcn sizes: `text-xs → meta`,
`text-sm → ui`, `text-lg/heading → title` (restyled by hand, not mechanically).

> Decision on the two ambiguous one-offs: `11px` body text snaps **down** to
> `meta` (10.5) and `12px` snaps **up** to `body` (12.5). Both are sub-pixel
> visual shifts and there is no backwards-compat concern.

**Elevation** — three named shadow tokens via `@theme` (`--shadow-<name>` →
`shadow-<name>`):

| token            | value                          | replaces (inline)            |
|------------------|--------------------------------|------------------------------|
| `shadow-pop`     | `0 18px 44px -12px rgb(0 0 0 / .7)` | menus/popovers (SessionPane, Library, LibraryToolbar) |
| `shadow-overlay` | `0 24px 60px -12px rgb(0 0 0 / .7)` | SpacesOverlay                |
| `shadow-drag`    | `0 12px 30px -8px rgb(0 0 0 / .7)`  | WatchSetGrid drag ghost      |

**Control heights** — two semantic CSS vars in `:root`, used as `h-[var(--h-bar)]`
/ `h-[var(--h-row)]`:

| var        | px | use                                                        |
|------------|----|------------------------------------------------------------|
| `--h-bar`  | 32 | in-body section/toolbar header rows (unifies the `h-8` headers **and** `SessionPane`'s odd `h-[29px]`) |
| `--h-row`  | 26 | dense list rows (`SessionBench`, `LibraryTree`, menu items) |

The app-chrome `TopBar` (46px) and `StatusBar` stay as-is — they're distinct
chrome, not in-body bars.

**Unchanged:** the surface/text/accent/status/identity ramp, the radii scale, the
`.dark` bootstrap, and the shadcn semantic mapping. Adding a theme later = add a
parallel token block and a `.theme-x` class selector; documented, no code changes.

### 2. Reusable primitives (`src/lib/components/shell/`)

All presentational, Svelte 5 runes + snippets, no domain coupling. Each reproduces
the established look (now via tokens), so adoption is a clean refactor.

- **`IconButton.svelte`** — props `{ icon: IconName; size?: number = 14; box?: number = 24; title?: string; onclick?: () => void; active?: boolean = false; tone?: 'default' | 'accent' | 'danger' = 'default'; disabled?: boolean; class?: string }`. Renders a `grid place-items-center rounded-md transition-colors` button at `box`px, `text-ink-3` + `hover:bg-[var(--hover-tint)] hover:text-ink-2`; `active` → `text-ink-1` (or `text-brand-hi` when `tone='accent'`); `tone='danger'` → red hover.
- **`Surface.svelte`** — elevated panel chrome. Props `{ elevation?: 'pop' | 'overlay' = 'pop'; class?: string; children }`. Renders `rounded-[10px] border border-hair-strong bg-panel shadow-<elevation>` + children (`class` can override radius/width).
- **`Popover.svelte`** — dismiss behavior over `Surface`. Props `{ open: boolean (bindable); class?: string; elevation?; children; onclose?: () => void }`. When open: a fixed `inset-0 z-40` backdrop button (closes) + a `z-50` `Surface` positioned by the caller's `class`, animated with `lg-rise`. Caller wraps in a `relative` anchor.
- **`MenuItem.svelte`** — a menu row. Props `{ icon?: IconName; tone?: 'default' | 'danger' = 'default'; onclick?: () => void; disabled?; children }`. `flex w-full items-center gap-2 px-2.5 h-[var(--h-row)] text-left text-ui … hover:bg-[var(--hover-tint)]`; danger → red text + red-tinted hover.
- **`SectionLabel.svelte`** — `{ class?; children }` → `font-mono text-micro font-semibold uppercase tracking-[0.14em] text-ink-3`. `SidePaneSection` becomes a thin wrapper that renders a `SectionLabel` + its body.
- **`ConfirmButton.svelte`** — two-step destructive, rendered as a `MenuItem`. Props `{ idleLabel: string; confirmLabel: string; onconfirm: () => void; icon?: IconName = 'trash' }`. Internal `armed` state: first click arms (swaps to `confirmLabel`), second click fires `onconfirm`. Resets on unmount (menu close).

**Adoption sites:**
- `IconButton` → `SidePane` (pin, close), `SessionPane` (menu trigger, focus, close), Library page (panel-right toggle, menu trigger), `SessionBench` + Library rail (search toggle).
- `Surface`/`Popover`/`MenuItem` → `SessionPane` actions menu, Library page ⋯ menu, `LibraryToolbar` new-file popover; `SpacesOverlay` uses `Surface elevation="overlay"`.
- `SectionLabel` → `SidePaneSection`, `SessionBench` group headers, `LibraryToolbar` label, settings sections.
- `ConfirmButton` → `SessionPane` delete, Library page delete.

### 3. Migrate the five laggards

Restyle to tokens + dense aesthetic + the new primitives, matching Sessions/Library
chrome. **Behavior/UX unchanged**; only styling + markup structure change.

- `routes/messages/+page.svelte` — dense thread layout: `text-title` page header, `Surface`/`SectionLabel` group framing, token text, identity-colored kind badges (reuse `AgentAvatar`/identity tokens), dense rows.
- `routes/settings/+page.svelte` — `SectionLabel` sections, token text, `IconButton`s, token inputs.
- `NewSessionDialog.svelte` — restyle the dialog body to tokens + dense (drop `bg-muted/40`, bare `border`, `text-sm`).
- `MessageComposer.svelte` — token-styled select/input/send (drop `bg-background`, bare `border`, `text-sm`).
- `MessagesPanel.svelte` — token text (drop `text-muted-foreground`, `text-xs/sm`).

### 4. Token-discipline rule

Feature/view code (everything outside `lib/components/ui/`) uses **only**: Legend
token classes (`bg-shell/app/panel/raised/inset`, `text-ink-1/2/3`, the
`text-micro…title` scale, `shadow-pop/overlay/drag`, `border-hair[-strong]`,
`var(--accent*)`, `var(--hover-tint)`, `var(--h-bar/--h-row)`, status/identity
vars) and the shell primitives. It must NOT use raw shadcn neutral classes
(`text-muted-foreground`, `bg-muted`, `bg-background`, `bg-accent`, …), ad-hoc
hex/rgba (shadows now come from tokens; box-shadow rgba inside the token
definitions is fine), or ad-hoc font sizes (`text-[Npx]`). The `ui/` layer is the
only place shadcn semantic classes appear.

## Documentation

- **`docs/DESIGN_SYSTEM.md`** (new) — canonical reference: the token ramp + type
  scale + elevation + control heights + radii; the accent/theming model ("how to
  re-theme" = swap `--accent`; "how to add a theme" = parallel token block under a
  class selector); the primitive catalog (each component, its props, when to use);
  the token-discipline rule.
- **`docs/ARCHITECTURE.md`** — add a short "Design System" subsection under the
  frontend section pointing to `DESIGN_SYSTEM.md` and naming the token + primitive
  seams.
- **`CLAUDE.md`** — in the Frontend section, point to `DESIGN_SYSTEM.md` and state
  the token-discipline rule in one line.

## Testing / verification

- `cd frontend && bun run check` → 0 errors, 0 warnings.
- `cd frontend && bun run build` → succeeds.
- A grep gate: no shadcn neutral classes (`text-muted-foreground|bg-muted|bg-background|bg-accent|text-foreground|bg-card|bg-popover|text-accent-foreground`) and no ad-hoc `text-[…px]` remain outside `lib/components/ui/`.
- Manual visual pass (`just dev` → click through Sessions, Library, Messages,
  Settings, new-session dialog) — requires a human eye; called out at hand-off.

## Out of scope

Light mode / runtime theme switching; `ui/` primitive internals; the `Terminal`
xterm background string (xterm needs a literal color, not a CSS var — left as the
single intentional hardcoded color, kept equal to `--bg-app`); any backend work.

## File plan

**New**
- `src/lib/components/shell/IconButton.svelte`
- `src/lib/components/shell/Surface.svelte`
- `src/lib/components/shell/Popover.svelte`
- `src/lib/components/shell/MenuItem.svelte`
- `src/lib/components/shell/SectionLabel.svelte`
- `src/lib/components/shell/ConfirmButton.svelte`
- `docs/DESIGN_SYSTEM.md`

**Modified**
- `src/routes/layout.css` — type scale, elevation, control-height tokens.
- `src/lib/components/shell/SidePane.svelte`, `SidePaneSection.svelte`,
  `SpacesOverlay.svelte`, `TopBar.svelte` (icon-button/label adoption as it fits).
- `src/lib/components/sessions/SessionPane.svelte`, `SessionBench.svelte`,
  `WatchSetGrid.svelte` (shadow token).
- `src/lib/components/library/LibraryTree.svelte`, `LibraryToolbar.svelte`,
  `src/routes/library/+page.svelte`.
- `src/routes/messages/+page.svelte`, `src/routes/settings/+page.svelte`,
  `src/lib/components/NewSessionDialog.svelte`, `MessageComposer.svelte`,
  `MessagesPanel.svelte`.
- `docs/ARCHITECTURE.md`, `CLAUDE.md`.
