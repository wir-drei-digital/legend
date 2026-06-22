# Pane Header Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract one generic `PaneHeader` shell primitive and adopt it in all three window surfaces so every pane shares the same header icons/styles and a universal drag · maximize · close action set.

**Architecture:** A new dumb `PaneHeader.svelte` (no store imports) owns the generic header chrome — active tint, drag handle, maximize/restore, close — and exposes `title` / `meta?` / `actions?` snippets for per-surface content. `SessionPane`, `FileSurface`, and `MessagesSurface` each render `<PaneHeader>` instead of a hand-rolled `<div>`.

**Tech Stack:** SvelteKit 2, Svelte 5 runes, Tailwind v4 + Legend design tokens.

## Global Constraints

- Svelte 5 runes only (`$props`, `$derived`, `$state`); named snippets are passed as snippet props.
- Token discipline: Legend tokens (`text-ink-*`, `bg-shell`, `text-ui/meta/micro`, `border-hair`) + shell primitives only — no raw shadcn neutrals, no ad-hoc hex, no ad-hoc `text-[Npx]`.
- All header buttons use `IconButton` at `box={24} size={14}`.
- `window.confirm/alert/prompt` are banned (Tauri webview no-ops) — use in-UI confirm (already via `ConfirmButton`).
- **Verification is `bun run check` (svelte-check) + a live browser pass.** Component/runes unit tests are out of scope per `frontend/vite.config.ts` (`environment: 'node'`, `include: ['src/**/*.test.ts']`). Do NOT add `.svelte` component tests.
- Commands run from `frontend/`: `cd /Users/daniel/Development/legend/frontend`.

---

### Task 1: Create the `PaneHeader` primitive

**Files:**
- Create: `frontend/src/lib/components/shell/PaneHeader.svelte`

**Interfaces:**
- Consumes: `TileLayout` from `$lib/shell/tiling.svelte` (uses `.activeId`, `.focusedId`, `.draggingId`, `.focus(id)`, `.restore()`); `IconButton` from `./IconButton.svelte`.
- Produces: a component with props
  `{ tileId: string; layout: TileLayout; grab?: (e: PointerEvent) => void; onClose: () => void; title: Snippet; meta?: Snippet; actions?: Snippet }`.
  Renders `title` inside the drag handle, `meta` loosely-spaced, then a tight `gap-0.5` cluster of `actions` + maximize (`expand`/`shrink`) + close.

- [ ] **Step 1: Write the component**

Create `frontend/src/lib/components/shell/PaneHeader.svelte` with exactly this content:

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import IconButton from './IconButton.svelte';

	// Generic window-pane header. Owns the chrome every surface shares — active
	// tint, the drag-to-retile handle, maximize/restore, and close — and leaves
	// surface identity (`title`), status (`meta`), and extra icon buttons
	// (`actions`) to snippet props. A dumb shell primitive: no store imports.
	let {
		tileId,
		layout,
		grab,
		onClose,
		title,
		meta,
		actions
	}: {
		tileId: string;
		layout: TileLayout;
		grab?: (e: PointerEvent) => void;
		onClose: () => void;
		title: Snippet;
		meta?: Snippet;
		actions?: Snippet;
	} = $props();

	const active = $derived(layout.activeId === tileId);
	const focusedMode = $derived(layout.focusedId === tileId);
	const dragging = $derived(layout.draggingId === tileId);

	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}
</script>

<div
	class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-2.5"
	style:background={active
		? 'color-mix(in oklab, var(--accent) 7%, var(--bg-shell))'
		: 'var(--bg-shell)'}
>
	<!-- drag handle: press + drag a tile by its header to re-tile the grid -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div
		class="flex min-w-0 flex-1 items-center gap-2 {dragging ? 'cursor-grabbing' : 'cursor-grab'}"
		onpointerdown={(e) => grab?.(e)}
		role="button"
		tabindex="-1"
		title="Drag to re-tile"
	>
		{@render title()}
	</div>

	{#if meta}{@render meta()}{/if}

	<!-- actions cluster: surface extras + universal maximize/close as one tight unit -->
	<div class="flex shrink-0 items-center gap-0.5">
		{#if actions}{@render actions()}{/if}
		<IconButton
			icon={focusedMode ? 'shrink' : 'expand'}
			size={14}
			box={24}
			title={focusedMode ? 'Restore grid' : 'Maximize pane'}
			active={focusedMode}
			tone="accent"
			onclick={toggleFocus}
		/>
		<IconButton icon="close" size={14} box={24} title="Close pane" onclick={onClose} />
	</div>
</div>
```

- [ ] **Step 2: Run svelte-check to verify the component compiles**

Run: `cd /Users/daniel/Development/legend/frontend && bun run check`
Expected: PASS — no new errors/warnings referencing `PaneHeader.svelte`. (The component is not yet imported anywhere; this confirms it type-checks in isolation.)

- [ ] **Step 3: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/shell/PaneHeader.svelte
git commit -m "feat(shell): add generic PaneHeader primitive"
```

---

### Task 2: Adopt `PaneHeader` in `SessionPane`

**Files:**
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte`

**Interfaces:**
- Consumes: `PaneHeader` from `$lib/components/shell/PaneHeader.svelte` (Task 1).
- Produces: no exported API change — `SessionPane` keeps the same props.

Context: the current header is the `<!-- header -->` block spanning the `<div class="flex h-[var(--h-bar)] …">` at line ~208 through its closing `</div>` at line ~362 (the block containing the drag handle, badge/time, transport toggle, `VDiv`, the actions cluster with `more`/`panel-right`/`expand`/`close`). The outer surface `<div>` (with `onpointerdown={() => layout.setActive(tileId)}` and `style:opacity`) and the body below it stay.

- [ ] **Step 1: Import `PaneHeader`**

In the `<script>` block, add the import alongside the other shell imports (e.g. right after the `IconButton` import line):

```svelte
	import PaneHeader from '$lib/components/shell/PaneHeader.svelte';
```

- [ ] **Step 2: Remove now-unused derived state and helper**

Delete these three lines from the `<script>` (the header now owns active tint, focus state, and the maximize toggle). `dragging` and `active`… — keep `dragging` (the outer container still uses it); remove only `active`, `focusedMode`, and `toggleFocus`:

Delete:
```svelte
	const active = $derived(layout.activeId === tileId);
```
```svelte
	const focusedMode = $derived(layout.focusedId === tileId);
```
And delete the whole helper at the bottom of the script:
```svelte
	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}
```

Leave `const dragging = $derived(layout.draggingId === tileId);` in place.

- [ ] **Step 3: Replace the header markup with `<PaneHeader>`**

Replace the entire `<!-- header -->` block (from `<!-- header -->` through the `</div>` that closes the `flex h-[var(--h-bar)]` header row — i.e. everything down to and including the line `</div>` right before `<!-- stream (live terminal) + optional in-tile Details -->`) with:

```svelte
		<!-- header -->
		<PaneHeader {tileId} {layout} {grab} {onClose}>
			{#snippet title()}
				<StatusDot color={live.dotColor} pulse={live.pulse} size={6} />
				{#if editingName}
					<!-- stopPropagation so typing/clicking doesn't start a header drag -->
					<input
						class="shrink-0 rounded-[5px] border border-hair-strong bg-app px-1 text-ui font-semibold text-ink-1 outline-none"
						bind:value={nameDraft}
						onpointerdown={(e) => e.stopPropagation()}
						onblur={commitRename}
						onkeydown={(e) => {
							if (e.key === 'Enter') {
								e.preventDefault();
								commitRename();
							} else if (e.key === 'Escape') {
								e.preventDefault();
								editingName = false;
							}
						}}
						use:autofocus
					/>
				{:else}
					<span class="shrink-0 text-ui font-semibold text-ink-1">
						{session.name || session.harness_id}
					</span>
				{/if}
				<span
					class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
					style:color="var({identity.colorVar})"
				>
					{identity.tag}
				</span>
				<span class="min-w-0 flex-1 truncate text-meta text-ink-3">{summary}</span>
			{/snippet}

			{#snippet meta()}
				{#if badge}
					<span class="shrink-0">
						{#if badge.kind === 'new'}
							<StateBadge kind="new" count={badge.count} />
						{:else}
							<StateBadge kind={badge.kind} />
						{/if}
					</span>
				{/if}
				{#if time}
					<span class="shrink-0 font-mono text-micro text-ink-3">{time}</span>
				{/if}
				{#if canSwitch}
					<!-- transport toggle: only when the harness speaks both rich + term -->
					<div class="flex shrink-0 items-center gap-1.5">
						{#if switchError}
							<span class="text-micro" style:color="var(--red)" title={switchError}>
								{switchError}
							</span>
						{/if}
						<div class="flex overflow-hidden rounded-[7px] border border-hair-strong text-micro">
							<button
								type="button"
								title="Rich (ACP) conversation"
								disabled={switching}
								class="px-2 py-0.5 font-bold disabled:opacity-50 {session.transport === 'acp'
									? 'bg-brand text-app'
									: 'text-ink-2'}"
								onclick={() => switchTransport('acp')}
							>
								rich
							</button>
							<button
								type="button"
								title="Terminal"
								disabled={switching}
								class="px-2 py-0.5 font-bold disabled:opacity-50 {session.transport === 'terminal'
									? 'bg-brand text-app'
									: 'text-ink-2'}"
								onclick={() => switchTransport('terminal')}
							>
								term
							</button>
						</div>
					</div>
				{/if}
				<VDiv height={18} />
			{/snippet}

			{#snippet actions()}
				<div class="relative">
					<IconButton
						icon="more"
						size={14}
						box={24}
						title="More actions"
						active={menuOpen}
						onclick={() => (menuOpen = !menuOpen)}
					/>
					<Popover bind:open={menuOpen} class="right-0 top-[28px] w-[150px]">
						{#if isLive}
							<MenuItem icon="pause" onclick={suspend}>Suspend</MenuItem>
						{:else}
							<MenuItem
								icon="refresh"
								onclick={() => {
									void resume();
									menuOpen = false;
								}}
							>
								{resumeLabel}
							</MenuItem>
						{/if}
						<MenuItem icon="pencil" onclick={startRename}>Rename</MenuItem>
						<div class="my-1 h-px bg-hair"></div>
						<ConfirmButton
							idleLabel="Delete session"
							confirmLabel="Confirm delete"
							onconfirm={remove}
						/>
					</Popover>
				</div>
				<IconButton
					icon="panel-right"
					size={14}
					box={24}
					title="Details"
					active={detailsOpen}
					tone="accent"
					onclick={() => (detailsOpen = !detailsOpen)}
				/>
			{/snippet}
		</PaneHeader>
```

- [ ] **Step 4: Run svelte-check**

Run: `cd /Users/daniel/Development/legend/frontend && bun run check`
Expected: PASS — 0 errors. In particular, no "unused" warnings for `active`/`focusedMode`/`toggleFocus` (they were removed) and no "`grab` is declared but never read" (now passed to `PaneHeader`).

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/sessions/SessionPane.svelte
git commit -m "refactor(sessions): render SessionPane header via PaneHeader"
```

---

### Task 3: Adopt `PaneHeader` in `FileSurface` (fixes old icons)

**Files:**
- Modify: `frontend/src/lib/components/library/FileSurface.svelte`

**Interfaces:**
- Consumes: `PaneHeader` from `$lib/components/shell/PaneHeader.svelte` (Task 1).
- Produces: no exported API change.

Context: the current header is the `<!-- header -->` block — `<div class="flex h-[var(--h-bar)] …">` at line ~62 through its closing `</div>` at line ~103 (drag handle with breadcrumbs, `Unsaved`, `Save`, and `IconButton`s `columns`/`eye`/`panel-right`/`more`/`close`, all at `box={20}`). The outer surface `<div>` and the body below stay.

- [ ] **Step 1: Import `PaneHeader`**

In the `<script>` block, add after the `IconButton` import:

```svelte
	import PaneHeader from '$lib/components/shell/PaneHeader.svelte';
```

- [ ] **Step 2: Remove now-unused derived state and helper**

Delete from the `<script>`:
```svelte
	const active = $derived(layout.activeId === tileId);
```
```svelte
	const focusedMode = $derived(layout.focusedId === tileId);
```
And delete the helper:
```svelte
	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}
```

Leave `const dragging = $derived(layout.draggingId === tileId);` and `const layout = $derived(workspaceStore.active.layout);` in place.

- [ ] **Step 3: Replace the header markup with `<PaneHeader>`**

Replace the entire `<!-- header -->` block (the `<div class="flex h-[var(--h-bar)] …">…</div>` through the `</div>` right before `<!-- body -->`) with:

```svelte
		<!-- header -->
		<PaneHeader {tileId} {layout} {grab} onClose={() => workspaceStore.closeTile(tileId)}>
			{#snippet title()}
				{#if path}
					<span class="shrink-0 text-meta text-ink-3">Library</span>
					{#each crumbs as c, i (i)}
						<Icon name="chevron-right" size={11} class="shrink-0 text-ink-3" />
						<span class="truncate text-ui {i === crumbs.length - 1 ? 'font-semibold text-ink-1' : 'text-ink-3'}">{c}</span>
					{/each}
				{:else}
					<span class="text-ui text-ink-3">Select a file</span>
				{/if}
			{/snippet}

			{#snippet meta()}
				{#if dirty}<span class="shrink-0 text-meta text-warn">Unsaved</span>{/if}
				<Button size="sm" class="h-7 px-2.5 text-meta" onclick={() => path && filesStore.save(path)} disabled={!dirty}>Save</Button>
			{/snippet}

			{#snippet actions()}
				<IconButton icon="columns" size={14} box={24} title="Split right" onclick={() => workspaceStore.splitActive()} />
				<IconButton icon="panel-right" size={14} box={24} title="Details" active={detailsOpen} tone="accent" onclick={() => (detailsOpen = !detailsOpen)} />
				<div class="relative">
					<IconButton icon="more" size={14} box={24} title="More actions" active={menuOpen} onclick={() => (menuOpen = !menuOpen)} />
					<Popover bind:open={menuOpen} class="right-0 top-[26px] w-[160px]">
						{#if path}
							<ConfirmButton idleLabel="Delete file" confirmLabel="Confirm delete" onconfirm={confirmDelete} />
						{:else}
							<p class="px-2.5 py-1.5 text-meta text-ink-3">No file selected.</p>
						{/if}
					</Popover>
				</div>
			{/snippet}
		</PaneHeader>
```

Note the deliberate changes vs the old header: the `eye` focus button is gone (maximize is now the header's `expand`/`shrink`), the inline `close` button is gone (header owns it), and `box={20}` → `box={24}` on every button.

- [ ] **Step 4: Run svelte-check**

Run: `cd /Users/daniel/Development/legend/frontend && bun run check`
Expected: PASS — 0 errors; no unused-symbol warnings for `active`/`focusedMode`/`toggleFocus`, no unread `grab`.

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/library/FileSurface.svelte
git commit -m "refactor(library): render FileSurface header via PaneHeader, unify icons"
```

---

### Task 4: Add a header to `MessagesSurface` + final live verification

**Files:**
- Modify: `frontend/src/lib/components/surfaces/MessagesSurface.svelte`

**Interfaces:**
- Consumes: `PaneHeader` from `$lib/components/shell/PaneHeader.svelte` (Task 1); `workspaceStore` from `$lib/shell/workspace.svelte` (`.active.layout`, `.closeTile(id)`); `Icon` from `$lib/components/shell/Icon.svelte`.
- Produces: no exported API change — keeps `{ tileId, params, grab }` props.

Context: `MessagesSurface` currently has NO pane header — its template is `<div class="h-full min-h-0"><div class="flex h-full flex-col gap-3 p-4"><h1>Messages</h1> … <MessageComposer /></div></div>`. It must gain the standard surface-root treatment (active-on-pointerdown, drag opacity) plus a `PaneHeader`, and drop the inner `<h1>`.

- [ ] **Step 1: Add imports and layout/dragging state**

In the `<script>` block, add these imports near the top (after the existing `MessageComposer` / `SectionLabel` imports):

```svelte
	import PaneHeader from '$lib/components/shell/PaneHeader.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
```

Then, just after the `let { tileId, params, grab } = $props();` line, add:

```svelte
	const layout = $derived(workspaceStore.active.layout);
	const dragging = $derived(layout.draggingId === tileId);
```

- [ ] **Step 2: Replace the template wrapper + drop the `<h1>`**

Replace the outer markup. Change the opening:

```svelte
<div class="h-full min-h-0">
	<div class="flex h-full flex-col gap-3 p-4">
		<h1 class="text-title font-semibold text-ink-1">Messages</h1>

		<div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto">
```

to:

```svelte
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => layout.setActive(tileId)}
>
	<PaneHeader {tileId} {layout} {grab} onClose={() => workspaceStore.closeTile(tileId)}>
		{#snippet title()}
			<Icon name="message" size={14} class="shrink-0 text-ink-3" />
			<span class="shrink-0 text-ui font-semibold text-ink-1">Messages</span>
			<span class="font-mono text-micro text-ink-3">{messagesStore.messages.length}</span>
		{/snippet}
	</PaneHeader>

	<div class="flex min-h-0 flex-1 flex-col gap-3 p-4">
		<div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto">
```

Then update the closing tags at the very end of the template. The old ending is:

```svelte
			<MessageComposer />
		</div>
	</div>
</div>
```

Keep it as-is — the three closing `</div>`s now map to: the `gap-3 p-4` body, … wait, recount. After the change there are these open elements at the end: the `overflow-y-auto` scroll div (closed before `<MessageComposer />`), the `gap-3 p-4` body div, and the outer surface div. So the tail becomes:

```svelte
			</div>

			<MessageComposer />
		</div>
	</div>
```

i.e. the scroll-area `</div>` (already present after the `{/each}`), then `<MessageComposer />`, then `</div>` (closes `gap-3 p-4` body), then `</div>` (closes the outer surface div). Confirm the final structure is:
- outer surface `<div>` (flex-col, opacity, onpointerdown)
  - `<PaneHeader>…</PaneHeader>`
  - body `<div class="flex min-h-0 flex-1 flex-col gap-3 p-4">`
    - scroll `<div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto">…</div>`
    - `<MessageComposer />`

- [ ] **Step 3: Run svelte-check**

Run: `cd /Users/daniel/Development/legend/frontend && bun run check`
Expected: PASS — 0 errors; `grab` and `params` no longer flagged unused (`grab` is passed to `PaneHeader`; `params` keeps its existing contract comment).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/surfaces/MessagesSurface.svelte
git commit -m "feat(messages): give MessagesSurface a unified PaneHeader (drag/maximize/close)"
```

- [ ] **Step 5: Final live verification (all three surfaces)**

Start the dev server (`just dev` from repo root, open `:4173`) or use the preview tooling. Then confirm, capturing a screenshot as proof:

1. **Messages** — open the Messages surface in a tile. The header now shows the `message` icon + "Messages" + count, and the maximize + close buttons. Drag the header → the tile re-tiles. Click maximize → it fills the grid; click restore → it returns. Click close → the tile closes.
2. **Files** — open a file tile. The focus button is now the `expand`/`shrink` glyph (not `eye`); buttons are the larger `box={24}` size and sit in one tight cluster ending with close. Save / split / details / more all still work.
3. **Sessions** — open a session tile. Header looks unchanged; maximize/restore, close, more menu, details, and (when available) the transport toggle all still work. Active-tile tint still appears on the focused pane.

Expected: all three render the same header chrome; no console errors (`preview_console_logs`).

---

## Self-Review

**Spec coverage:**
- New `PaneHeader` primitive (spec §"New primitive") → Task 1. ✓
- SessionPane adoption (spec table row 1) → Task 2. ✓
- FileSurface old-icon fix (spec table row 2) → Task 3. ✓
- MessagesSurface gains header (spec table row 3) → Task 4. ✓
- Universal drag/maximize/close + active tint (spec §Responsibilities) → Task 1 implements; Tasks 2–4 consume. ✓
- Verification = svelte-check + live (spec §Verification) → each task Step "Run svelte-check" + Task 4 Step 5. ✓
- Out-of-scope items (registry contract, splitActive/closeTile/focus, SidePane body) → untouched by all tasks. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code step shows the full markup. ✓

**Type consistency:** `PaneHeader` prop names (`tileId`, `layout`, `grab`, `onClose`, `title`, `meta`, `actions`) defined in Task 1 are used identically in Tasks 2–4. `layout` methods referenced (`activeId`, `focusedId`, `draggingId`, `focus`, `restore`, `setActive`) match `TileLayout`'s existing surface (already used by the current SessionPane/FileSurface). `onClose` is `() => void` everywhere. ✓
