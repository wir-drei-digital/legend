# Library Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Library view as a polished three-pane workbench, extracting two reusable, decoupled primitives — a generic `WorkbenchLayout` (rail | primary | side) and a generic `SidePane` (header + sectioned body + footer).

**Architecture:** The Library page (no shell `bench`) fills its body with `WorkbenchLayout`. A `libraryStore` runes singleton holds view state + file CRUD so the shell-rendered toolbar, rail, editor, and side pane share one source of truth (mirrors `sessionsStore`). `WorkbenchLayout` and `SidePane` stay generic and state-agnostic; only Library-specific pieces read the store. Everything is wired to the existing real file API — only metadata with real backing is shown.

**Tech Stack:** SvelteKit 2 (SPA, `ssr = false`), Svelte 5 runes, Tailwind v4 + Legend design tokens, Bun. No backend changes.

## Global Constraints

- **Svelte 5 runes only.** `$state` / `$derived` / `$props` / `$bindable` / snippets. Follow existing patterns (`SessionBench.svelte`, `sessions.svelte.ts`). No legacy stores, no `export let`.
- **Legend design tokens only.** Use `bg-shell` / `bg-app` / `bg-panel` / `bg-raised` / `bg-inset`, `border-hair` / `border-hair-strong`, `text-ink-1/2/3`, `text-warn`, `var(--accent)` / `var(--accent-soft)` / `var(--accent-hi)`, `var(--hover-tint)`, `var(--red)`. **Never** reintroduce the old shadcn neutral classes (`text-muted-foreground`, `bg-accent`, bare `border`, `bg-background`) in any file this plan touches.
- **No `window.confirm` / `alert` / `prompt`** — they are no-ops in the Tauri webview. All confirmations are in-UI (two-step buttons or a popover).
- **No new dependencies. No test framework.** This repo has no frontend test runner. Verification for every task is: `cd frontend && bun run check` (svelte-check, must report 0 errors) and `cd frontend && bun run build` (must succeed), plus the manual steps stated in the task. Run the app with `just dev` and open `http://localhost:5173/library`.
- **Client-only access is fine** (`ssr = false`), but still guard `window` / `localStorage` / `navigator` reads so `bun run build`'s SSR/prerender pass never throws.
- **Commit after each task.** End every commit message with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: Foundations — `formatBytes`, `filterTree`, new icon glyphs

Shared helpers + icons consumed by later tasks. No UI yet.

**Files:**
- Modify: `frontend/src/lib/shell/format.ts` (append `formatBytes`)
- Modify: `frontend/src/lib/library.ts` (append `filterTree`)
- Modify: `frontend/src/lib/components/shell/Icon.svelte` (add `file`, `panel-right`, `link` glyphs)

**Interfaces:**
- Produces: `formatBytes(n: number): string` — e.g. `formatBytes(4096) === "4 KB"`.
- Produces: `filterTree(nodes: TreeNode[], query: string): TreeNode[]` — pruned copy keeping ancestor folders of name matches.
- Produces: `IconName` union gains `'file' | 'panel-right' | 'link'`.

- [ ] **Step 1: Add `formatBytes` to `format.ts`**

Append to `frontend/src/lib/shell/format.ts`:

```ts
/** Compact byte size, e.g. "0 B", "4 KB", "1.6 MB". */
export function formatBytes(n: number): string {
	if (!Number.isFinite(n) || n <= 0) return '0 B';
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
	const v = n / 1024 ** i;
	const s = i === 0 ? String(v) : String(Math.round(v * 10) / 10);
	return `${s} ${units[i]}`;
}
```

- [ ] **Step 2: Add `filterTree` to `library.ts`**

Append to `frontend/src/lib/library.ts` (after `buildTree`):

```ts
/**
 * Prunes the tree to nodes whose name matches `query` (case-insensitive),
 * keeping the ancestor folders of any match so the path stays navigable.
 * Returns a new tree; the input is not mutated.
 */
export function filterTree(nodes: TreeNode[], query: string): TreeNode[] {
	const q = query.trim().toLowerCase();
	if (!q) return nodes;
	const walk = (list: TreeNode[]): TreeNode[] => {
		const out: TreeNode[] = [];
		for (const n of list) {
			if (n.type === 'dir') {
				const children = walk(n.children);
				if (children.length || n.name.toLowerCase().includes(q)) {
					out.push({ ...n, children });
				}
			} else if (n.name.toLowerCase().includes(q)) {
				out.push(n);
			}
		}
		return out;
	};
	return walk(nodes);
}
```

- [ ] **Step 3: Add three glyphs to `Icon.svelte`**

In the `IconName` union (the `module` script block), add the three names. Change:

```ts
		| 'chevron-down'
		| 'chevron-right'
		| 'corner-down-left';
```

to:

```ts
		| 'chevron-down'
		| 'chevron-right'
		| 'corner-down-left'
		| 'file'
		| 'panel-right'
		| 'link';
```

Then, in the markup, immediately before the final `{:else if name === 'corner-down-left'}` branch (order doesn't matter, but keep it tidy), add:

```svelte
		{:else if name === 'file'}
			<path d="M13 3.5H6.5A1.5 1.5 0 005 5v14a1.5 1.5 0 001.5 1.5h11A1.5 1.5 0 0019 19V9.5z" />
			<path d="M13 3.5V9.5h6" />
		{:else if name === 'panel-right'}
			<rect x="3.5" y="4.5" width="17" height="15" rx="2.4" />
			<path d="M14.5 4.5v15" />
		{:else if name === 'link'}
			<path d="M9.5 14.5l5-5" />
			<path d="M8 11l-2.2 2.2a3.1 3.1 0 004.4 4.4L12 16" />
			<path d="M16 13l2.2-2.2a3.1 3.1 0 00-4.4-4.4L12 8" />
```

- [ ] **Step 4: Verify it type-checks**

Run: `cd frontend && bun run check`
Expected: completes with **0 errors, 0 warnings** (svelte-check). The new exports and icon names resolve.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/shell/format.ts frontend/src/lib/library.ts frontend/src/lib/components/shell/Icon.svelte
git commit -m "feat(frontend): library workbench foundations (formatBytes, filterTree, icons)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `libraryStore` runes singleton

Holds Library view state + file CRUD, moving the logic out of the page so the shell-rendered toolbar can share it. Mirrors `sessionsStore`.

**Files:**
- Create: `frontend/src/lib/stores/library.svelte.ts`

**Interfaces:**
- Consumes: `listTree`, `readFile`, `writeFile`, `deleteFile`, `buildTree`, `TreeNode`, `LibraryEntry` from `$lib/library` (Task 1 left these intact).
- Produces: `libraryStore` singleton with reactive fields `entries: LibraryEntry[]`, `tree: TreeNode[]`, `selected: string | null`, `content: string`, `savedContent: string`, `error: string`, `loaded: boolean`; derived `dirty: boolean`, `selectedEntry: LibraryEntry | null`; async actions `refresh()`, `open(path: string)`, `save()`, `create(path: string)`, `remove()`.

- [ ] **Step 1: Create the store**

Create `frontend/src/lib/stores/library.svelte.ts`:

```ts
import {
	buildTree,
	deleteFile,
	listTree,
	readFile,
	writeFile,
	type LibraryEntry,
	type TreeNode
} from '$lib/library';

/**
 * Shared Library view-state. Lives in a singleton (not page-local) because the
 * "New file" action is a shell-rendered toolbar outside the page's component
 * tree — the toolbar, rail, editor and side pane all read/write this store, the
 * same way sessionsStore/watchSet coordinate the Sessions chrome.
 */
class LibraryStore {
	entries = $state<LibraryEntry[]>([]);
	tree = $state<TreeNode[]>([]);
	selected = $state<string | null>(null);
	content = $state('');
	savedContent = $state('');
	error = $state('');
	loaded = $state(false);

	dirty = $derived(this.content !== this.savedContent);
	selectedEntry = $derived<LibraryEntry | null>(
		this.selected ? (this.entries.find((e) => e.path === this.selected) ?? null) : null
	);

	// pending-open path for the unsaved-changes guard (click the file again to discard)
	#pendingOpen: string | null = null;

	async refresh(): Promise<void> {
		try {
			this.entries = await listTree();
			this.tree = buildTree(this.entries);
			this.loaded = true;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to load library';
		}
	}

	async open(path: string): Promise<void> {
		if (this.dirty && this.#pendingOpen !== path) {
			this.#pendingOpen = path;
			this.error = 'Unsaved changes — click the file again to discard them.';
			return;
		}
		this.#pendingOpen = null;
		this.error = '';
		try {
			this.content = await readFile(path);
			this.savedContent = this.content;
			this.selected = path;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	async save(): Promise<void> {
		if (!this.selected) return;
		this.error = '';
		try {
			await writeFile(this.selected, this.content);
			this.savedContent = this.content;
			await this.refresh();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	async create(path: string): Promise<void> {
		const p = path.trim();
		if (!p) return;
		this.error = '';
		try {
			await writeFile(p, '');
			await this.refresh();
			await this.open(p);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to create file';
		}
	}

	async remove(): Promise<void> {
		if (!this.selected) return;
		this.error = '';
		try {
			await deleteFile(this.selected);
			this.selected = null;
			this.content = '';
			this.savedContent = '';
			await this.refresh();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to delete';
		}
	}
}

export const libraryStore = new LibraryStore();
```

- [ ] **Step 2: Verify it type-checks**

Run: `cd frontend && bun run check`
Expected: 0 errors. (`$derived` with a type argument and `this.` field references compile under Svelte 5 runes-in-classes.)

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/stores/library.svelte.ts
git commit -m "feat(frontend): libraryStore runes singleton for view state + file CRUD

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Generic `SidePane` + `SidePaneSection` + `SidePaneField`

The reusable right-pane primitive (also for the future expanded chat view). Presentational only — driven by props/snippets.

**Files:**
- Create: `frontend/src/lib/components/shell/SidePane.svelte`
- Create: `frontend/src/lib/components/shell/SidePaneSection.svelte`
- Create: `frontend/src/lib/components/shell/SidePaneField.svelte`

**Interfaces:**
- Consumes: `Icon`, `IconName` from `$lib/components/shell/Icon.svelte`.
- Produces: `SidePane` with props `{ title: string; icon?: IconName; onClose?: () => void; onPin?: () => void; pinned?: boolean; actions?: Snippet; children: Snippet; footer?: Snippet }`.
- Produces: `SidePaneSection` props `{ label: string; children: Snippet }`.
- Produces: `SidePaneField` props `{ label: string; value: string }`.

- [ ] **Step 1: Create `SidePaneField.svelte`**

```svelte
<script lang="ts">
	let { label, value }: { label: string; value: string } = $props();
</script>

<div class="flex items-baseline justify-between gap-3 text-[11.5px]">
	<span class="shrink-0 text-ink-3">{label}</span>
	<span class="min-w-0 truncate text-ink-1" title={value}>{value}</span>
</div>
```

- [ ] **Step 2: Create `SidePaneSection.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	let { label, children }: { label: string; children: Snippet } = $props();
</script>

<section class="flex flex-col gap-2">
	<h3 class="font-mono text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-3">{label}</h3>
	{@render children()}
</section>
```

- [ ] **Step 3: Create `SidePane.svelte`**

```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon, { type IconName } from './Icon.svelte';

	let {
		title,
		icon,
		onClose,
		onPin,
		pinned = false,
		actions,
		children,
		footer
	}: {
		title: string;
		icon?: IconName;
		onClose?: () => void;
		onPin?: () => void;
		pinned?: boolean;
		actions?: Snippet;
		children: Snippet;
		footer?: Snippet;
	} = $props();
</script>

<aside class="flex h-full min-h-0 w-full flex-col bg-shell">
	<!-- header -->
	<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair px-3">
		{#if icon}<Icon name={icon} size={14} class="shrink-0 text-ink-3" />{/if}
		<span class="min-w-0 flex-1 truncate text-[11.5px] font-semibold text-ink-2">{title}</span>
		{#if actions}{@render actions()}{/if}
		{#if onPin}
			<button
				type="button"
				onclick={onPin}
				title={pinned ? 'Unpin' : 'Pin'}
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
				class:text-brand-hi={pinned}
			>
				<Icon name="star" size={13} fill={pinned} />
			</button>
		{/if}
		{#if onClose}
			<button
				type="button"
				onclick={onClose}
				title="Close panel"
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
			>
				<Icon name="close" size={13} />
			</button>
		{/if}
	</div>

	<!-- body -->
	<div class="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-3 py-3.5">
		{@render children()}
	</div>

	{#if footer}
		<div class="shrink-0 border-t border-hair p-2.5">
			{@render footer()}
		</div>
	{/if}
</aside>
```

- [ ] **Step 4: Verify it type-checks and builds**

Run: `cd frontend && bun run check && bun run build`
Expected: check reports 0 errors; build succeeds. (No consumer yet — manual rendering is verified in Task 7.)

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/shell/SidePane.svelte frontend/src/lib/components/shell/SidePaneSection.svelte frontend/src/lib/components/shell/SidePaneField.svelte
git commit -m "feat(frontend): generic SidePane detail-pane primitive

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Generic `WorkbenchLayout`

Reusable three-region layout: fixed rail | flex primary | resizable + collapsible side. Owns arrangement only; hosts whatever snippets it's given.

**Files:**
- Create: `frontend/src/lib/components/shell/WorkbenchLayout.svelte`

**Interfaces:**
- Produces: `WorkbenchLayout` with props `{ rail: Snippet; primary: Snippet; side: Snippet; sideOpen?: boolean (bindable, default true); sideWidth?: number (bindable, default 320); railWidth?: number (default 178); storageKey?: string }`. Resize clamps `sideWidth` to 240px–40vw. When `storageKey` set, `{ width, open }` persist to `localStorage`.

- [ ] **Step 1: Create the component**

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import type { Snippet } from 'svelte';

	let {
		rail,
		primary,
		side,
		sideOpen = $bindable(true),
		sideWidth = $bindable(320),
		railWidth = 178,
		storageKey
	}: {
		rail: Snippet;
		primary: Snippet;
		side: Snippet;
		sideOpen?: boolean;
		sideWidth?: number;
		railWidth?: number;
		storageKey?: string;
	} = $props();

	const MIN = 240;
	let hydrated = $state(false);

	function clampWidth(w: number): number {
		const max = Math.round(window.innerWidth * 0.4);
		return Math.max(MIN, Math.min(max, w));
	}

	onMount(() => {
		if (storageKey) {
			const raw = localStorage.getItem(storageKey);
			if (raw) {
				try {
					const v = JSON.parse(raw);
					if (typeof v.width === 'number') sideWidth = clampWidth(v.width);
					if (typeof v.open === 'boolean') sideOpen = v.open;
				} catch {
					// ignore a corrupt persisted value
				}
			}
		}
		hydrated = true;
	});

	// Persist only after hydration so we never clobber storage with defaults.
	$effect(() => {
		if (!storageKey || !hydrated) return;
		localStorage.setItem(storageKey, JSON.stringify({ width: sideWidth, open: sideOpen }));
	});

	// Drag the seam (left edge of the side region): dragging left widens the side.
	function beginResize(e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const startX = e.clientX;
		const startW = sideWidth;
		document.body.style.userSelect = 'none';
		const move = (ev: PointerEvent) => {
			sideWidth = clampWidth(startW + (startX - ev.clientX));
		};
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			document.body.style.userSelect = '';
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
	}
</script>

<div class="flex h-full w-full overflow-hidden">
	<!-- rail -->
	<div
		class="flex shrink-0 flex-col overflow-hidden border-r border-hair bg-shell"
		style:width="{railWidth}px"
	>
		{@render rail()}
	</div>

	<!-- primary -->
	<div class="flex min-w-0 flex-1 flex-col overflow-hidden bg-app">
		{@render primary()}
	</div>

	<!-- side (with resize seam) -->
	{#if sideOpen}
		<div class="relative z-20 w-px shrink-0 bg-hair">
			<div
				class="absolute inset-y-0 -inset-x-[3px] cursor-ew-resize"
				role="separator"
				aria-orientation="vertical"
				tabindex="-1"
				onpointerdown={beginResize}
			></div>
		</div>
		<div class="flex shrink-0 flex-col overflow-hidden bg-shell" style:width="{sideWidth}px">
			{@render side()}
		</div>
	{/if}
</div>
```

- [ ] **Step 2: Verify it type-checks and builds**

Run: `cd frontend && bun run check && bun run build`
Expected: check 0 errors; build succeeds. (`window`/`localStorage` are only touched inside `onMount`/`$effect`/event handlers, so the SSR/prerender pass never reaches them.)

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/components/shell/WorkbenchLayout.svelte
git commit -m "feat(frontend): generic WorkbenchLayout (rail | primary | resizable side)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Restyle `LibraryTree` (Legend tokens + dirty dot)

Move it under `library/`, restyle to the design system, add a `dirtyPath` badge. Stays purely presentational (filtering happens in the page via `filterTree`).

**Files:**
- Create: `frontend/src/lib/components/library/LibraryTree.svelte`

(The old `frontend/src/lib/components/LibraryTree.svelte` is left in place this task and deleted in Task 7, when the page switches its import — that keeps both tasks independently green.)

**Interfaces:**
- Consumes: `TreeNode` from `$lib/library`; `Icon` from `$lib/components/shell/Icon.svelte` (`folder`, `file`, `chevron-right`, `chevron-down` — all exist after Task 1).
- Produces: `LibraryTree` props `{ nodes: TreeNode[]; selected: string | null; dirtyPath?: string | null; onselect: (path: string) => void }`.

- [ ] **Step 1: Create the restyled component**

Create `frontend/src/lib/components/library/LibraryTree.svelte`:

```svelte
<script lang="ts">
	import type { TreeNode } from '$lib/library';
	import Icon from '$lib/components/shell/Icon.svelte';

	let {
		nodes,
		selected,
		dirtyPath = null,
		onselect
	}: {
		nodes: TreeNode[];
		selected: string | null;
		dirtyPath?: string | null;
		onselect: (path: string) => void;
	} = $props();

	let collapsed = $state<Record<string, boolean>>({});
</script>

{#snippet node(n: TreeNode, depth: number)}
	{#if n.type === 'dir'}
		<button
			type="button"
			class="flex h-[26px] w-full items-center gap-1.5 pr-2 text-left text-[11.5px] text-ink-2 transition-colors hover:bg-[var(--hover-tint)]"
			style:padding-left="{depth * 12 + 12}px"
			aria-expanded={!collapsed[n.path]}
			onclick={() => (collapsed[n.path] = !collapsed[n.path])}
		>
			<Icon
				name={collapsed[n.path] ? 'chevron-right' : 'chevron-down'}
				size={12}
				class="shrink-0 text-ink-3"
			/>
			<Icon name="folder" size={13} class="shrink-0 text-ink-3" />
			<span class="min-w-0 truncate">{n.name}</span>
		</button>
		{#if !collapsed[n.path]}
			{#each n.children as child (child.path)}
				{@render node(child, depth + 1)}
			{/each}
		{/if}
	{:else}
		{@const active = selected === n.path}
		<button
			type="button"
			class="relative flex h-[26px] w-full items-center gap-1.5 pr-2 text-left text-[11.5px] transition-colors hover:bg-[var(--hover-tint)]"
			style:padding-left="{depth * 12 + 12}px"
			style:background={active ? 'var(--accent-soft)' : undefined}
			style:color={active ? 'var(--text-1)' : 'var(--text-2)'}
			onclick={() => onselect(n.path)}
		>
			<span
				class="absolute left-0 top-0 h-full w-[2px]"
				style:background={active ? 'var(--accent)' : 'transparent'}
			></span>
			<Icon name="file" size={13} class="shrink-0 text-ink-3" />
			<span class="min-w-0 flex-1 truncate">{n.name}</span>
			{#if dirtyPath === n.path}
				<span
					class="size-1.5 shrink-0 rounded-full"
					style:background="var(--accent)"
					title="Unsaved changes"
				></span>
			{/if}
		</button>
	{/if}
{/snippet}

{#each nodes as n (n.path)}
	{@render node(n, 0)}
{:else}
	<p class="px-3 py-2 text-[11px] text-ink-3">Empty.</p>
{/each}
```

- [ ] **Step 2: Verify it type-checks**

Run: `cd frontend && bun run check`
Expected: 0 errors. Both the old and new `LibraryTree` exist; the new one is unused for now (svelte-check does not error on an unused component).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/components/library/LibraryTree.svelte
git commit -m "feat(frontend): restyle LibraryTree to Legend tokens + dirty dot

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `LibraryToolbar` + register it in the view

The top-bar "New file" action with an in-UI new-file popover (no `window.prompt`). Registered as the Library view's `toolbar`.

**Files:**
- Create: `frontend/src/lib/components/library/LibraryToolbar.svelte`
- Modify: `frontend/src/lib/shell/views.ts`

**Interfaces:**
- Consumes: `libraryStore` (Task 2) — calls `libraryStore.create(path)`; `Button` from `$lib/components/ui/button`; `Icon`.
- Produces: default-exported `LibraryToolbar` component; `views.ts` `library` entry gains `toolbar: LibraryToolbar` and drops `sub`.

- [ ] **Step 1: Create `LibraryToolbar.svelte`**

```svelte
<script lang="ts">
	import { libraryStore } from '$lib/stores/library.svelte';
	import { Button } from '$lib/components/ui/button';
	import Icon from '$lib/components/shell/Icon.svelte';

	let open = $state(false);
	let path = $state('');

	async function create() {
		const p = path.trim();
		if (!p) return;
		await libraryStore.create(p);
		path = '';
		open = false;
	}
</script>

<div class="relative">
	<Button size="sm" class="h-[30px] px-3" onclick={() => (open = !open)}>
		<Icon name="plus" size={14} class="mr-1" />
		New file
	</Button>

	{#if open}
		<button
			type="button"
			class="fixed inset-0 z-40 cursor-default"
			aria-label="Close"
			onclick={() => (open = false)}
		></button>
		<div
			class="absolute right-0 top-[36px] z-50 w-[280px] rounded-[10px] border border-hair-strong bg-panel p-2.5 shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)]"
			style:animation="lg-rise 0.12s ease-out"
		>
			<label
				for="new-file-path"
				class="mb-1.5 block font-mono text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-3"
			>
				New file path
			</label>
			<!-- svelte-ignore a11y_autofocus -->
			<input
				id="new-file-path"
				autofocus
				bind:value={path}
				placeholder="skills/my-skill.md"
				onkeydown={(e) => {
					if (e.key === 'Enter') {
						e.preventDefault();
						void create();
					} else if (e.key === 'Escape') {
						open = false;
					}
				}}
				class="w-full rounded-[7px] border border-hair-strong bg-inset px-2 py-1.5 text-[11.5px] text-ink-1 placeholder:text-ink-3 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
			/>
			<div class="mt-2 flex justify-end gap-2">
				<Button
					size="sm"
					variant="outline"
					class="h-7 px-2.5 text-[11px]"
					onclick={() => (open = false)}
				>
					Cancel
				</Button>
				<Button size="sm" class="h-7 px-2.5 text-[11px]" onclick={create} disabled={!path.trim()}>
					Create
				</Button>
			</div>
		</div>
	{/if}
</div>
```

- [ ] **Step 2: Register the toolbar in `views.ts`**

In `frontend/src/lib/shell/views.ts`, add the import near the other component imports:

```ts
import LibraryToolbar from '$lib/components/library/LibraryToolbar.svelte';
```

Replace the existing `library` entry:

```ts
		{
			id: 'library',
			label: 'Library',
			href: '/library',
			icon: 'folder',
			defaultPinned: true,
			sub: () => 'shared knowledge, skills & artifacts'
		},
```

with:

```ts
		{
			id: 'library',
			label: 'Library',
			href: '/library',
			icon: 'folder',
			defaultPinned: true,
			toolbar: LibraryToolbar
		},
```

- [ ] **Step 3: Verify type-check + build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors; build succeeds.

- [ ] **Step 4: Manual check**

Run `just dev`, open `http://localhost:5173/library`. Expected: a **New file** button now sits in the top bar. Clicking it opens the path popover; entering `notes/scratch.md` + Enter creates the file (it appears once the page is rewritten in Task 7 — for now confirm the popover opens/closes and the backend receives the create, e.g. the file exists on disk under the library path). Escape / Cancel / outside-click dismiss the popover.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/library/LibraryToolbar.svelte frontend/src/lib/shell/views.ts
git commit -m "feat(frontend): Library New-file toolbar + register as view toolbar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Rewrite the Library page to compose the workbench

Replace the page markup: rail (filter + `LibraryTree`), primary (breadcrumb editor with Save / side-toggle / delete menu), side (`SidePane` with real metadata + Copy reference). Wire everything to `libraryStore`. Remove the now-dead old `LibraryTree`.

**Files:**
- Modify (rewrite): `frontend/src/routes/library/+page.svelte`
- Delete: `frontend/src/lib/components/LibraryTree.svelte`

**Interfaces:**
- Consumes: `WorkbenchLayout`, `SidePane`, `SidePaneSection`, `SidePaneField` (`$lib/components/shell/`); `LibraryTree` (`$lib/components/library/`); `libraryStore` (`$lib/stores/library.svelte`); `filterTree` (`$lib/library`); `relativeTime`, `formatBytes` (`$lib/shell/format`); `Icon`, `Button`.

- [ ] **Step 1: Delete the old `LibraryTree`**

```bash
git rm frontend/src/lib/components/LibraryTree.svelte
```

- [ ] **Step 2: Rewrite `+page.svelte`**

Replace the entire contents of `frontend/src/routes/library/+page.svelte` with:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import WorkbenchLayout from '$lib/components/shell/WorkbenchLayout.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import { Button } from '$lib/components/ui/button';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { filterTree } from '$lib/library';
	import { relativeTime, formatBytes } from '$lib/shell/format';

	let sideOpen = $state(true);
	let sideWidth = $state(320);

	// rail filter
	let searching = $state(false);
	let query = $state('');
	const filtered = $derived(query.trim() ? filterTree(libraryStore.tree, query) : libraryStore.tree);
	const fileCount = $derived(libraryStore.entries.filter((e) => e.type === 'file').length);

	// editor ⋯ menu (two-step delete)
	let menuOpen = $state(false);
	let confirmingDelete = $state(false);

	const sel = $derived(libraryStore.selected);
	const crumbs = $derived(sel ? sel.split('/') : []);

	function copyReference() {
		if (sel && typeof navigator !== 'undefined') void navigator.clipboard?.writeText(sel);
	}

	async function confirmDelete() {
		await libraryStore.remove();
		menuOpen = false;
		confirmingDelete = false;
	}

	onMount(() => void libraryStore.refresh());
</script>

<WorkbenchLayout storageKey="legend:library:side" bind:sideOpen bind:sideWidth>
	{#snippet rail()}
		<!-- rail header -->
		<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
			{#if searching}
				<!-- svelte-ignore a11y_autofocus -->
				<input
					autofocus
					bind:value={query}
					onblur={() => {
						if (!query) searching = false;
					}}
					placeholder="Filter…"
					class="min-w-0 flex-1 bg-transparent text-[11.5px] text-ink-1 placeholder:text-ink-3 focus:outline-none"
				/>
			{:else}
				<span class="text-[11.5px] font-semibold text-ink-2">Explorer</span>
				<span class="font-mono text-[10.5px] text-ink-3">{fileCount}</span>
				<div class="flex-1"></div>
			{/if}
			<button
				type="button"
				onclick={() => {
					searching = !searching;
					if (!searching) query = '';
				}}
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
				title="Filter library"
			>
				<Icon name={searching ? 'close' : 'search'} size={13} />
			</button>
		</div>
		<!-- tree -->
		<div class="min-h-0 flex-1 overflow-y-auto py-1.5">
			<LibraryTree
				nodes={filtered}
				selected={libraryStore.selected}
				dirtyPath={libraryStore.dirty ? libraryStore.selected : null}
				onselect={(p) => libraryStore.open(p)}
			/>
		</div>
	{/snippet}

	{#snippet primary()}
		<!-- editor header -->
		<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair px-3">
			{#if sel}
				<div class="flex min-w-0 flex-1 items-center gap-1 text-[11.5px]">
					<span class="shrink-0 text-ink-3">Library</span>
					{#each crumbs as c, i (i)}
						<Icon name="chevron-right" size={11} class="shrink-0 text-ink-3" />
						<span
							class="truncate {i === crumbs.length - 1 ? 'font-semibold text-ink-1' : 'text-ink-3'}"
						>
							{c}
						</span>
					{/each}
				</div>
				{#if libraryStore.dirty}
					<span class="shrink-0 text-[10.5px] text-warn">Unsaved</span>
				{/if}
				<Button
					size="sm"
					class="h-7 px-2.5 text-[11px]"
					onclick={() => libraryStore.save()}
					disabled={!libraryStore.dirty}
				>
					Save
				</Button>
				<button
					type="button"
					onclick={() => (sideOpen = !sideOpen)}
					title="Toggle details"
					class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
					class:text-brand-hi={sideOpen}
				>
					<Icon name="panel-right" size={14} />
				</button>
				<div class="relative shrink-0">
					<button
						type="button"
						onclick={() => (menuOpen = !menuOpen)}
						aria-expanded={menuOpen}
						title="More actions"
						class="grid size-6 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
						class:text-ink-1={menuOpen}
					>
						<Icon name="more" size={14} />
					</button>
					{#if menuOpen}
						<button
							type="button"
							class="fixed inset-0 z-40 cursor-default"
							aria-label="Close menu"
							onclick={() => {
								menuOpen = false;
								confirmingDelete = false;
							}}
						></button>
						<div
							class="absolute right-0 top-[30px] z-50 w-[160px] overflow-hidden rounded-[10px] border border-hair-strong bg-panel py-1 shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)]"
							style:animation="lg-rise 0.12s ease-out"
						>
							{#if confirmingDelete}
								<button
									type="button"
									onclick={confirmDelete}
									class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] font-medium transition-colors hover:bg-[color-mix(in_oklab,var(--red)_16%,transparent)]"
									style:color="var(--red)"
								>
									<Icon name="trash" size={13} />
									Confirm delete
								</button>
							{:else}
								<button
									type="button"
									onclick={() => (confirmingDelete = true)}
									class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] transition-colors hover:bg-[color-mix(in_oklab,var(--red)_12%,transparent)]"
									style:color="var(--red)"
								>
									<Icon name="trash" size={13} />
									Delete file
								</button>
							{/if}
						</div>
					{/if}
				</div>
			{:else}
				<span class="text-[11.5px] text-ink-3">Select a file</span>
			{/if}
		</div>

		{#if libraryStore.error}
			<div class="shrink-0 border-b border-hair px-3 py-1.5 text-[11px]" style:color="var(--red)">
				{libraryStore.error}
			</div>
		{/if}

		<!-- editor body -->
		{#if sel}
			<textarea
				bind:value={libraryStore.content}
				onkeydown={(e) => {
					if ((e.metaKey || e.ctrlKey) && e.key === 's') {
						e.preventDefault();
						void libraryStore.save();
					}
				}}
				class="min-h-0 flex-1 resize-none bg-app p-3.5 font-mono text-[12px] leading-relaxed text-ink-1 outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex flex-1 items-center justify-center">
				<p class="text-[12px] text-ink-3">Select a file from the tree, or create one.</p>
			</div>
		{/if}
	{/snippet}

	{#snippet side()}
		<SidePane title="Details" icon="file" onClose={() => (sideOpen = false)}>
			{#if libraryStore.selectedEntry}
				{@const e = libraryStore.selectedEntry}
				<SidePaneSection label="File">
					<div class="flex items-center gap-2.5">
						<span
							class="grid size-9 shrink-0 place-items-center rounded-[9px] border border-hair bg-inset text-ink-2"
						>
							<Icon name="file" size={18} />
						</span>
						<div class="min-w-0">
							<p class="truncate text-[12.5px] font-semibold text-ink-1">
								{e.path.split('/').at(-1)}
							</p>
							<p class="text-[11px] text-ink-3">
								{e.type === 'dir' ? 'Folder' : 'Document'} · {formatBytes(e.size)}
							</p>
						</div>
					</div>
				</SidePaneSection>
				<SidePaneSection label="Details">
					<SidePaneField label="Modified" value={relativeTime(e.mtime) || '—'} />
					<SidePaneField label="Path" value={e.path} />
				</SidePaneSection>
			{:else}
				<p class="text-[11.5px] text-ink-3">No file selected.</p>
			{/if}

			{#snippet footer()}
				<Button
					size="sm"
					variant="outline"
					class="h-8 w-full text-[11px]"
					disabled={!sel}
					onclick={copyReference}
				>
					<Icon name="link" size={13} class="mr-1.5" />
					Copy reference
				</Button>
			{/snippet}
		</SidePane>
	{/snippet}
</WorkbenchLayout>
```

- [ ] **Step 3: Verify type-check + build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors; build succeeds. (The old `LibraryTree` import is gone; the new path resolves.)

- [ ] **Step 4: Manual verification (the real test)**

Run `just dev`, open `http://localhost:5173/library`:
- Tree renders with Legend styling (folders with chevrons, files with the file glyph, the void/shell palette). Selecting a file loads it; the selected row shows the accent spine + soft background.
- Editor: breadcrumb reads `Library › … › <file>`; typing flips **Unsaved** on and shows the **dirty dot** on the tree row; `⌘S` (or the **Save** button) saves and clears both.
- **Toggle** (panel-right icon) and the `SidePane` **close** button both collapse the side pane; the editor widens. Re-open and **drag the seam** to resize. Reload the page — width + open/closed state **persist**.
- Side pane shows real **name / type · size / modified / path**; **Copy reference** copies the path (paste to confirm). No Source/State/Fed-to/Versions sections appear.
- **⋯ → Delete file → Confirm delete** removes the file and clears the editor.
- Filter: the rail search icon reveals a filter input that prunes the tree (matching files keep their folders).
- Create a file via the top-bar **New file** popover — it appears in the tree and opens.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/routes/library/+page.svelte
git commit -m "feat(frontend): rebuild Library view on WorkbenchLayout + SidePane

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Svelte 5 snippet-as-prop:** defining `{#snippet footer()}…{/snippet}` *inside* `<SidePane>…</SidePane>` passes it as the `footer` prop; the rest of the inner markup becomes `children`. Likewise `{#snippet rail()/primary()/side()}` inside `<WorkbenchLayout>` fill those three props.
- **`bind:value={libraryStore.content}`** binds straight to the store's `$state` field — supported in Svelte 5. Same for `bind:sideOpen` / `bind:sideWidth` on `WorkbenchLayout` (they're `$bindable`).
- If `bun run check` flags an unused `@const` or import, remove it — don't suppress.
- Do **not** add agent badges, version lists, sync state, or a pin button to the Library side pane: there's no backing data (spec "Honesty rule"). `SidePane` supports `onPin` and arbitrary `SidePaneSection`s for when that data exists.
