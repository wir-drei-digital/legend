# Design System Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Legend's design system fully tokenized, reusable, and consistent — add the missing tokens (type scale, elevation, control heights), extract the recurring UI patterns into shell primitives, adopt them across every view, migrate the un-styled screens, and document it all.

**Architecture:** Tokens live in `src/routes/layout.css` (Tailwind v4 `@theme` + `:root`). New presentational primitives live in `src/lib/components/shell/`. Feature/view code uses only Legend tokens + these primitives; the shadcn `ui/` layer is untouched (it inherits the palette via the existing semantic-var mapping). This is an early-stage codebase: **backwards compatibility is not a concern** — rewrite working views and snap off-scale values onto the canonical scale for cleanliness.

**Tech Stack:** SvelteKit 2 (SPA, `ssr=false`), Svelte 5 runes + snippets, Tailwind v4 + the Legend token layer, Bun.

## Global Constraints

- **Svelte 5 runes + snippets only.** `$props`/`$state`/`$derived`/`$bindable`/`{@render}`. No `export let`, no legacy slots.
- **No frontend test runner exists.** Verification for every task = `cd frontend && bun run check` (svelte-check; **0 errors, 0 warnings**) and `cd frontend && bun run build` (succeeds). No TDD red/green. Do not add a test framework.
- **Token-discipline rule (feature/view code, i.e. everything outside `lib/components/ui/`):** use only Legend token classes — `bg-shell/app/panel/raised/inset`, `text-ink-1/2/3`, the `text-micro/meta/ui/body/title` scale, `shadow-pop/overlay/drag`, `border-hair[-strong]`, `var(--accent*)`, `var(--hover-tint)`, `h-[var(--h-bar)]`/`h-[var(--h-row)]`, status/identity vars — and the shell primitives. **Never** raw shadcn neutral classes (`text-muted-foreground`, `bg-muted`, `bg-background`, `bg-accent`, `text-foreground`, `bg-card`, `bg-popover`, `text-accent-foreground`, `bg-primary` outside the `Button` primitive), ad-hoc hex/rgba (the only allowed hex is `Terminal`'s xterm background and `AgentAvatar`'s `#fff`), or ad-hoc font sizes (`text-[Npx]`).
- **The `ui/` layer (`lib/components/ui/`) is OUT OF SCOPE** — do not edit it. It is the only place shadcn semantic classes legitimately appear.
- **No new dependencies.**
- **Work on branch `design-system-hardening`.** Commit after each task; end every commit message with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

**Type-scale migration map** (apply wherever `text-[Npx]` appears in feature code):
`9px,9.5px → text-micro` · `10px,10.5px,11px → text-meta` · `11.5px → text-ui` · `12px,12.5px → text-body` · `13px → text-title`. Larger one-offs in laggards: `text-xs → text-meta`, `text-sm → text-ui`, `text-lg → text-title`.

**Elevation map:** `shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)] → shadow-pop` · `shadow-[0_24px_60px_-12px_rgba(0,0,0,0.7)] → shadow-overlay` · `shadow-[0_12px_30px_-8px_rgba(0,0,0,0.7)] → shadow-drag`.

**Height map:** section/toolbar header `h-8`/`h-[29px] → h-[var(--h-bar)]` · dense list row `h-[26px] → h-[var(--h-row)]`.

---

### Task 1: Tokens — type scale, elevation, control heights

**Files:**
- Modify: `frontend/src/routes/layout.css`

**Interfaces:**
- Produces: Tailwind utilities `text-micro|meta|ui|body|title`, `shadow-pop|overlay|drag`; CSS vars `--h-bar` (32px), `--h-row` (26px) for `h-[var(--h-bar)]`/`h-[var(--h-row)]`.

- [ ] **Step 1: Add control-height vars to `:root`**

In `frontend/src/routes/layout.css`, inside the `:root { … }` block (after the `--radius` line), add:

```css
	/* Control heights (dense). Used as h-[var(--h-bar)] / h-[var(--h-row)]. */
	--h-bar: 32px; /* in-body section/toolbar header rows */
	--h-row: 26px; /* dense list rows + menu items */
```

- [ ] **Step 2: Add type-scale + elevation tokens to `@theme inline`**

In the `@theme inline { … }` block (alongside the existing `--font-*` and `--color-*` tokens), add:

```css
	/* Dense type scale — every UI font-size is one of these. */
	--text-micro: 9px;
	--text-meta: 10.5px;
	--text-ui: 11.5px;
	--text-body: 12.5px;
	--text-title: 13px;

	/* Elevation — three named float levels. */
	--shadow-pop: 0 18px 44px -12px rgb(0 0 0 / 0.7); /* menus, popovers */
	--shadow-overlay: 0 24px 60px -12px rgb(0 0 0 / 0.7); /* large floating panels */
	--shadow-drag: 0 12px 30px -8px rgb(0 0 0 / 0.7); /* drag ghost */
```

- [ ] **Step 3: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0 errors / 0 warnings; build succeeds. (The new utilities are defined; nothing consumes them yet — existing `text-[Npx]` still works, so the tree stays green.)

- [ ] **Step 4: Commit**

```bash
git add frontend/src/routes/layout.css
git commit -m "feat(frontend): tokenize type scale, elevation, control heights

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Atoms — `IconButton` + `SectionLabel`

**Files:**
- Create: `frontend/src/lib/components/shell/IconButton.svelte`
- Create: `frontend/src/lib/components/shell/SectionLabel.svelte`
- Modify: `frontend/src/lib/components/shell/SidePaneSection.svelte`

**Interfaces:**
- Consumes: `text-micro` (Task 1), `Icon`/`IconName`.
- Produces:
  - `IconButton` props `{ icon: IconName; size?: number = 14; box?: number = 24; title?: string; onclick?: (e: MouseEvent) => void; active?: boolean = false; tone?: 'default' | 'accent' | 'danger' = 'default'; disabled?: boolean; class?: string }`.
  - `SectionLabel` props `{ class?: string; children: Snippet }`.

- [ ] **Step 1: Create `IconButton.svelte`**

```svelte
<script lang="ts">
	import Icon, { type IconName } from './Icon.svelte';

	let {
		icon,
		size = 14,
		box = 24,
		title,
		onclick,
		active = false,
		tone = 'default',
		disabled = false,
		class: className = ''
	}: {
		icon: IconName;
		size?: number;
		box?: number;
		title?: string;
		onclick?: (e: MouseEvent) => void;
		active?: boolean;
		tone?: 'default' | 'accent' | 'danger';
		disabled?: boolean;
		class?: string;
	} = $props();

	const hover =
		tone === 'danger'
			? 'hover:bg-[color-mix(in_oklab,var(--red)_14%,transparent)] hover:text-[var(--red)]'
			: 'hover:bg-[var(--hover-tint)] hover:text-ink-2';
	const activeColor = $derived(tone === 'accent' ? 'var(--accent-hi)' : 'var(--text-1)');
</script>

<button
	type="button"
	{title}
	{disabled}
	{onclick}
	class="grid shrink-0 place-items-center rounded-md text-ink-3 transition-colors disabled:opacity-40 disabled:hover:bg-transparent {hover} {className}"
	style:width="{box}px"
	style:height="{box}px"
	style:color={active ? activeColor : undefined}
>
	<Icon name={icon} {size} />
</button>
```

- [ ] **Step 2: Create `SectionLabel.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	let { class: className = '', children }: { class?: string; children: Snippet } = $props();
</script>

<span
	class="font-mono text-micro font-semibold uppercase tracking-[0.14em] text-ink-3 {className}"
>
	{@render children()}
</span>
```

- [ ] **Step 3: Adopt `SectionLabel` in `SidePaneSection.svelte`**

Replace the whole file with:

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import SectionLabel from './SectionLabel.svelte';
	let { label, children }: { label: string; children: Snippet } = $props();
</script>

<section class="flex flex-col gap-2">
	<SectionLabel>{label}</SectionLabel>
	{@render children()}
</section>
```

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/shell/IconButton.svelte frontend/src/lib/components/shell/SectionLabel.svelte frontend/src/lib/components/shell/SidePaneSection.svelte
git commit -m "feat(frontend): IconButton + SectionLabel primitives

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Menu family — `Surface` + `Popover` + `MenuItem` + `ConfirmButton`

**Files:**
- Create: `frontend/src/lib/components/shell/Surface.svelte`
- Create: `frontend/src/lib/components/shell/Popover.svelte`
- Create: `frontend/src/lib/components/shell/MenuItem.svelte`
- Create: `frontend/src/lib/components/shell/ConfirmButton.svelte`

**Interfaces:**
- Consumes: `shadow-pop/overlay` + `--h-row` (Task 1), `Icon`/`IconName`, `lg-rise` keyframe (exists in `layout.css`).
- Produces:
  - `Surface` props `{ elevation?: 'pop' | 'overlay' = 'pop'; class?: string; children: Snippet }`.
  - `Popover` props `{ open?: boolean (bindable); class?: string; elevation?: 'pop' | 'overlay' = 'pop'; onclose?: () => void; children: Snippet }`. Renders a fixed backdrop + an absolutely-positioned `Surface` (positioned by the caller's `class`). Caller wraps in a `relative` anchor.
  - `MenuItem` props `{ icon?: IconName; tone?: 'default' | 'danger' = 'default'; onclick?: () => void; disabled?: boolean; children: Snippet }`.
  - `ConfirmButton` props `{ idleLabel: string; confirmLabel: string; onconfirm: () => void; icon?: IconName = 'trash' }`.

- [ ] **Step 1: Create `Surface.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	let {
		elevation = 'pop',
		class: className = '',
		children
	}: { elevation?: 'pop' | 'overlay'; class?: string; children: Snippet } = $props();
</script>

<div
	class="overflow-hidden rounded-[10px] border border-hair-strong bg-panel {elevation === 'overlay' ? 'shadow-overlay' : 'shadow-pop'} {className}"
>
	{@render children()}
</div>
```

- [ ] **Step 2: Create `Popover.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import Surface from './Surface.svelte';

	let {
		open = $bindable(false),
		class: className = '',
		elevation = 'pop',
		onclose,
		children
	}: {
		open?: boolean;
		class?: string;
		elevation?: 'pop' | 'overlay';
		onclose?: () => void;
		children: Snippet;
	} = $props();

	function close() {
		open = false;
		onclose?.();
	}
</script>

{#if open}
	<button
		type="button"
		class="fixed inset-0 z-40 cursor-default"
		aria-label="Close"
		onclick={close}
	></button>
	<div class="absolute z-50 {className}" style:animation="lg-rise 0.12s ease-out">
		<Surface {elevation} class="w-full">
			{@render children()}
		</Surface>
	</div>
{/if}
```

- [ ] **Step 3: Create `MenuItem.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon, { type IconName } from './Icon.svelte';
	let {
		icon,
		tone = 'default',
		onclick,
		disabled = false,
		children
	}: {
		icon?: IconName;
		tone?: 'default' | 'danger';
		onclick?: () => void;
		disabled?: boolean;
		children: Snippet;
	} = $props();
</script>

<button
	type="button"
	{disabled}
	{onclick}
	class="flex w-full items-center gap-2 px-2.5 text-left text-ui transition-colors disabled:opacity-40 {tone === 'danger' ? 'text-[var(--red)] hover:bg-[color-mix(in_oklab,var(--red)_14%,transparent)]' : 'text-ink-2 hover:bg-[var(--hover-tint)] hover:text-ink-1'}"
	style:height="var(--h-row)"
>
	{#if icon}<Icon name={icon} size={13} class={tone === 'danger' ? '' : 'text-ink-3'} />{/if}
	{@render children()}
</button>
```

- [ ] **Step 4: Create `ConfirmButton.svelte`**

```svelte
<script lang="ts">
	import type { IconName } from './Icon.svelte';
	import MenuItem from './MenuItem.svelte';
	let {
		idleLabel,
		confirmLabel,
		onconfirm,
		icon = 'trash'
	}: { idleLabel: string; confirmLabel: string; onconfirm: () => void; icon?: IconName } = $props();
	let armed = $state(false);
</script>

<MenuItem
	{icon}
	tone="danger"
	onclick={() => {
		if (armed) onconfirm();
		else armed = true;
	}}
>
	{armed ? confirmLabel : idleLabel}
</MenuItem>
```

- [ ] **Step 5: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds. (No consumers yet — adopted in Tasks 4–7.)

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/shell/Surface.svelte frontend/src/lib/components/shell/Popover.svelte frontend/src/lib/components/shell/MenuItem.svelte frontend/src/lib/components/shell/ConfirmButton.svelte
git commit -m "feat(frontend): Surface/Popover/MenuItem/ConfirmButton primitives

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Adopt tokens + primitives in shell & Sessions

Rule-driven refactor (no behavior change). Apply the Global-Constraints maps (type scale, elevation, height) and replace inline patterns with primitives.

**Files (modify):**
- `frontend/src/lib/components/shell/SidePane.svelte`
- `frontend/src/lib/components/shell/SpacesOverlay.svelte`
- `frontend/src/lib/components/shell/TopBar.svelte`
- `frontend/src/lib/components/shell/StatusBar.svelte`
- `frontend/src/lib/components/sessions/SessionPane.svelte`
- `frontend/src/lib/components/sessions/SessionBench.svelte`
- `frontend/src/lib/components/sessions/WatchSetGrid.svelte`

**Interfaces:**
- Consumes: `IconButton`, `Surface`, `Popover`, `MenuItem`, `ConfirmButton`, `SectionLabel` (Tasks 2–3); tokens (Task 1).

- [ ] **Step 1: Apply the token maps in every listed file**

In each file, replace every `text-[Npx]`, `shadow-[…]`, and header/row height per the Global-Constraints maps. Example (`SidePane.svelte` header): `text-[11.5px]` → `text-ui`, the `h-8` header bar → `h-[var(--h-bar)]`. Leave `text-[Npx]` only where N has no scale token AND it is a deliberate one-off (there should be none after mapping — every value maps).

- [ ] **Step 2: Replace inline icon-buttons with `IconButton`**

Pattern to replace (any inline button that is just a centered icon with hover-tint), e.g. in `SidePane.svelte`:

```svelte
<!-- before -->
<button type="button" onclick={onClose} title="Close panel"
	class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2">
	<Icon name="close" size={13} />
</button>
<!-- after -->
<IconButton icon="close" size={13} title="Close panel" onclick={onClose} />
```

Map `size-5 → box={20}`, `size-6 → box={24}`. For toggles that color when active (e.g. Library/SessionPane eye/panel toggles) pass `active={…} tone="accent"`. Import `IconButton` and drop the now-unused `Icon` import only if nothing else in the file uses `Icon`.

Apply to: `SidePane` (**close only** — see note), `SessionPane` (⋯ trigger, eye/focus, close), `SessionBench` (search toggle).

> **`SidePane` pin button stays custom.** It renders `<Icon name="star" fill={pinned} />` — the filled-star toggle. `IconButton` does not expose the icon `fill` prop, so converting it would lose that. Leave the pin `<button>` as-is (it's currently unused by any consumer anyway); only convert the close button.

- [ ] **Step 3: Replace the `SessionPane` actions menu with `Popover`/`MenuItem`/`ConfirmButton`**

In `SessionPane.svelte`, the `{#if menuOpen}` block (fixed backdrop + absolute `bg-panel shadow-[…]` panel + Suspend/Resume + two-step delete) becomes:

```svelte
<Popover bind:open={menuOpen} class="right-0 top-[26px] w-[150px]">
	{#if isLive}
		<MenuItem icon="pause" onclick={suspend}>Suspend</MenuItem>
	{:else}
		<MenuItem icon="refresh" onclick={() => { void resume(); menuOpen = false; }}>{resumeLabel}</MenuItem>
	{/if}
	<div class="my-1 h-px bg-hair"></div>
	<ConfirmButton idleLabel="Delete session" confirmLabel="Confirm delete" onconfirm={remove} />
</Popover>
```

Wrap the `⋯` trigger + `Popover` in a `relative` container (the trigger is now an `IconButton`). Remove the old `closeMenu`/`confirmingDelete` plumbing made dead by `Popover` + `ConfirmButton` (keep `menuOpen`).

- [ ] **Step 4: Replace `SpacesOverlay` panel chrome with `Surface`**

In `SpacesOverlay.svelte`, replace the outer `border border-hair-strong bg-panel … shadow-[0_24px_60px_-12px_rgba(0,0,0,0.7)]` panel element with `<Surface elevation="overlay" class="<keep positioning/width classes>">`. Apply the type-scale map to its text. Use `SectionLabel` for any mono-caps label inside.

- [ ] **Step 5: Apply elevation + scale in `WatchSetGrid`, `TopBar`, `StatusBar`**

`WatchSetGrid.svelte`: drag-ghost `shadow-[0_12px_30px_-8px_rgba(0,0,0,0.7)] → shadow-drag`; type-scale map. `TopBar.svelte` / `StatusBar.svelte`: type-scale map only (their `h-[46px]`/status-bar heights stay — they are app chrome, not in-body bars). Convert any inline icon-only buttons to `IconButton` where they match the pattern.

- [ ] **Step 6: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.

Then confirm no regressions in scope of this task:
Run: `cd frontend && grep -rnE "text-\[[0-9.]+px\]|shadow-\[0_" src/lib/components/shell src/lib/components/sessions`
Expected: no output (all migrated).

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/components/shell frontend/src/lib/components/sessions
git commit -m "refactor(frontend): adopt tokens + primitives across shell & Sessions

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Adopt tokens + primitives in Library

Same rule-driven refactor for the Library view.

**Files (modify):**
- `frontend/src/lib/components/library/LibraryTree.svelte`
- `frontend/src/lib/components/library/LibraryToolbar.svelte`
- `frontend/src/routes/library/+page.svelte`

**Interfaces:**
- Consumes: `IconButton`, `Surface`, `Popover`, `MenuItem`, `ConfirmButton`, `SectionLabel`, tokens.

- [ ] **Step 1: `LibraryTree.svelte`** — apply the type-scale map (`text-[11.5px] → text-ui`) and the row-height map (`h-[26px] → h-[var(--h-row)]`).

- [ ] **Step 2: `LibraryToolbar.svelte`** — wrap the new-file popover with `Popover bind:open={open} class="right-0 top-[36px] w-[280px]"` (drop the hand-rolled backdrop + `bg-panel shadow-[…]` div and the `lg-rise` inline style — `Popover` provides them). Replace the mono-caps "New file path" label with `<SectionLabel class="mb-1.5 block">`. Apply the type-scale map. Keep the `Button` (it's the `ui/` primitive) for New file / Create / Cancel.

- [ ] **Step 3: `routes/library/+page.svelte`** — (a) rail filter toggle + editor toolbar buttons (Save stays `Button`; the panel-right toggle and `⋯` trigger become `IconButton`, the toggle with `active={sideOpen} tone="accent"`); (b) replace the `⋯` delete menu with `Popover` + `ConfirmButton` (`idleLabel="Delete file" confirmLabel="Confirm delete" onconfirm={confirmDelete}`); (c) apply the type-scale + `h-[var(--h-bar)]` maps; (d) the SidePane "Copy reference" stays a `Button`. Remove `menuOpen`/`confirmingDelete` plumbing the primitives make dead (the `$effect` that resets them on file-switch stays, now just resetting `menuOpen`).

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.
Run: `cd frontend && grep -rnE "text-\[[0-9.]+px\]|shadow-\[0_" src/lib/components/library src/routes/library`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/library frontend/src/routes/library
git commit -m "refactor(frontend): adopt tokens + primitives across Library

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Migrate shared components (dialog, composer, panel)

Restyle to the Legend dense aesthetic + tokens + primitives. **Behavior/UX unchanged** — only styling and markup structure change. Replace every shadcn-neutral class with a token equivalent.

**Files (modify):**
- `frontend/src/lib/components/NewSessionDialog.svelte`
- `frontend/src/lib/components/MessageComposer.svelte`
- `frontend/src/lib/components/MessagesPanel.svelte`

**Class-swap reference** (apply throughout): `text-muted-foreground → text-ink-3` · `text-foreground → text-ink-1` · `bg-muted`/`bg-muted/40 → bg-inset` · `bg-background → bg-app` · bare `border → border-hair` (or `border-hair-strong` for inputs) · `text-destructive → text-[var(--red)]` · `text-xs → text-meta` · `text-sm → text-ui` · `rounded-md` stays (token radius). Mono-caps labels → `<SectionLabel>`.

- [ ] **Step 1: `MessagesPanel.svelte`** — apply the class-swap reference; dense spacing; `text-ui`/`text-meta` for rows; kind/meta in `text-ink-3`.

- [ ] **Step 2: `MessageComposer.svelte`** — restyle the `<select>` and `<input>` to `bg-inset border border-hair-strong text-ui text-ink-1` with token focus ring (`focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none`); send action uses the `Button` primitive; error text `text-[var(--red)] text-meta`.

- [ ] **Step 3: `NewSessionDialog.svelte`** — restyle the dialog body: drop `bg-muted/40` + bare `border` + `text-sm`; use `bg-inset`/`border-hair`/`text-ui`; section headers via `<SectionLabel>`; error text `text-[var(--red)]`. Keep the `Dialog`/`Input`/`Select`/`Button` `ui/` primitives; restyle only the surrounding markup.

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/NewSessionDialog.svelte frontend/src/lib/components/MessageComposer.svelte frontend/src/lib/components/MessagesPanel.svelte
git commit -m "refactor(frontend): migrate shared components onto the design system

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Migrate the Messages & Settings pages

Restyle both page bodies to the dense Legend aesthetic. Behavior unchanged.

**Files (modify):**
- `frontend/src/routes/messages/+page.svelte`
- `frontend/src/routes/settings/+page.svelte`

**Interfaces:**
- Consumes: tokens, `SectionLabel`, `IconButton`, `Surface`, `AgentAvatar` (existing, for identity), `Button` (`ui/`).

- [ ] **Step 1: `messages/+page.svelte`** — page header in `text-title font-semibold text-ink-1`; each delegation thread framed with a header using `<SectionLabel>` + count; message rows dense (`text-ui`, `text-ink-1/2/3`); replace the `kindBadge` map (`bg-accent text-accent-foreground`, `bg-muted text-muted-foreground`, amber-100/…) with token badges: `message → bg-[var(--accent-soft)] text-brand-hi`, `handoff → text-[var(--amber)]` + amber-soft, `system → bg-inset text-ink-3`; unread marker `text-[var(--amber)] text-meta`. Use `border-hair` for the group frames (or `Surface` if a raised card is wanted).

- [ ] **Step 2: `settings/+page.svelte`** — sections titled with `<SectionLabel>`; body text `text-ui text-ink-2`, secondary `text-ink-3`; `not configured`/error states use `text-ink-3`/`text-[var(--red)]`; the `<pre>` detail block → `bg-inset text-meta` (drop `bg-muted`); harness rows dense; keep `Button`/`Input` `ui/` primitives; convert any icon-only controls to `IconButton`.

- [ ] **Step 3: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/routes/messages/+page.svelte frontend/src/routes/settings/+page.svelte
git commit -m "refactor(frontend): migrate Messages & Settings pages onto the design system

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Documentation + final discipline gate

**Files:**
- Create: `docs/DESIGN_SYSTEM.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write `docs/DESIGN_SYSTEM.md`**

Cover, with the real values from `layout.css`: (a) the surface/text/accent/status/identity ramp; (b) the type scale table (`text-micro…title` + px + use); (c) elevation (`shadow-pop/overlay/drag`); (d) control heights (`--h-bar`/`--h-row`); (e) radii; (f) the theming model — "re-theme = swap `--accent`" and "add a theme = add a parallel token block under a `.theme-x` selector; dark-only today, no runtime switcher"; (g) the primitive catalog — `IconButton`, `Surface`, `Popover`, `MenuItem`, `ConfirmButton`, `SectionLabel`, `SidePane`(+Section/Field), `WorkbenchLayout` — each with its props and "use when"; (h) the token-discipline rule verbatim from Global Constraints, noting `ui/` is the only place shadcn semantic classes appear.

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`**

Add a short "Design System" subsection under the Frontend section: name the token layer (`layout.css`), the primitive layer (`components/shell/`), the shadcn-semantic-mapping seam, and link to `docs/DESIGN_SYSTEM.md` as canonical.

- [ ] **Step 3: Update `CLAUDE.md`**

In the Frontend section, add one line pointing to `docs/DESIGN_SYSTEM.md` and stating the token-discipline rule (feature code uses Legend tokens + shell primitives, never raw shadcn neutral classes / ad-hoc hex / ad-hoc `text-[Npx]`; `ui/` is the exception).

- [ ] **Step 4: Final discipline gate (whole tree)**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0/0; build succeeds.

Run the leftover-scan over ALL feature code (must be empty):
```bash
cd frontend && grep -rnE "text-muted-foreground|bg-muted|bg-background|bg-accent|text-foreground|bg-card|bg-popover|text-accent-foreground" --include="*.svelte" src/lib src/routes | grep -v "src/lib/components/ui/"
cd frontend && grep -rnE "text-\[[0-9.]+px\]" --include="*.svelte" src/lib src/routes | grep -v "src/lib/components/ui/"
```
Expected: both produce no output. If any line remains, fix it (apply the maps) before committing.

- [ ] **Step 5: Commit**

```bash
git add docs/DESIGN_SYSTEM.md docs/ARCHITECTURE.md CLAUDE.md
git commit -m "docs: design system reference + token-discipline rule

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Svelte 5 snippet-as-prop:** pass `children`/named snippets exactly as the existing `SidePane`/`WorkbenchLayout` do. `Popover`'s positioned content is its `children`; the caller supplies position+width via `class`.
- **`bind:open` on `Popover`** replaces the old local `menuOpen` + hand-rolled backdrop; keep the `menuOpen` `$state` and bind it.
- **Don't touch `lib/components/ui/`** — those shadcn primitives inherit the palette via the semantic mapping and are out of scope.
- **Adoption is behavior-preserving** for Tasks 4–5 (Sessions/Library already look right); for Tasks 6–7 you're bringing laggards UP to that look — match the density of `SessionBench`/`Library` (row heights, `text-ui` body, `text-micro` labels).
- If `bun run check` flags an unused import after replacing inline markup with a primitive, remove it.
