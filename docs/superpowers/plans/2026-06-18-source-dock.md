# Source Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the per-space rails with one persistent, draggable source dock (Files + Sessions); click or drag items into the grid to open surfaces; spaces become uniform grids; details move per-tile; the full workspace restores on launch with new sessions auto-appearing.

**Architecture:** A global `Dock` (left) renders pluggable `DockSource` sections. A dock row click calls `workspaceStore.openSurface`; a row drag uses a shared `dockDrag` store + `TileGrid`'s existing i3 hit-testing to place a new tile precisely. `LegendShell` renders `Dock` + the active space's `TileGrid` only (no per-space rail/side). Each file/session surface gets an in-tile `SidePane` Details toggle. Persistence restores all spaces; a reconcile pass appends running sessions not placed anywhere.

**Tech Stack:** SvelteKit 2 SPA (Svelte 5 runes), TypeScript, Tailwind v4 + Legend tokens, Vitest, Bun.

**Spec:** `docs/superpowers/specs/2026-06-18-source-dock-design.md`
**Branch:** `feat/source-dock` (spec committed at `ec0af07`).

## Global Constraints

- Frontend only (`frontend/`). No backend changes. Svelte 5 runes only.
- Design tokens only (`text-ink-1/2/3`, `bg-shell/app/panel/raised/inset`, `border-hair`/`border-hair-strong`, `text-brand/brand-hi`, `bg-[var(--accent-soft)]`, `text-ok/warn/bad`, type scale `text-micro/meta/ui/body/title`, `--h-bar`/`--h-row`); no raw shadcn neutral classes / ad-hoc hex / ad-hoc `text-[Npx]`; shadcn semantic classes only under `ui/`.
- NEVER `window.confirm`/`alert`/`prompt`. No `window`/`localStorage`/`document` at module top level (guard in `onMount`/handlers/`$effect`).
- `cd frontend && bun run check` → 0 errors / 0 warnings; `bun run test` (Vitest) passes; `bun run build` succeeds.
- Flat-positioned `TileGrid` invariant holds (render once, never reparent).
- `TileGrid` stays generic — it must NOT import `workspaceStore`; external-drop commits via an injected `onExternalDrop` prop.
- After the shell restructure (Task 5), re-verify Sessions + Library live parity (they now source from the dock).

## Resolved decisions (from the spec)

- Unify: dock replaces per-space rails; spaces are uniform grids.
- Click opens into the active space (focus-if-already-there); drag places precisely (i3 zones).
- Restore full last state; running sessions not placed anywhere auto-append to the Sessions space; stopped→resume tile, deleted→pruned (Sessions space) / unavailable (other spaces).
- Details is per-tile (in-window `SidePane`, hidden by default).

---

## File Structure

**New**
- `frontend/src/lib/shell/dock-drag.svelte.ts` — shared dock→grid drag state.
- `frontend/src/lib/shell/dock-sources.ts` — `DockSource` contract + `DOCK_SOURCES` registry.
- `frontend/src/lib/components/shell/Dock.svelte` — persistent dock shell.
- `frontend/src/lib/components/shell/sources/FilesSource.svelte` — files tree section.
- `frontend/src/lib/components/shell/sources/SessionsSource.svelte` — sessions list section.

**Modified**
- `frontend/src/lib/shell/tiling-core.ts` (+ `.test.ts`) — `unplacedRunning` pure helper.
- `frontend/src/lib/shell/workspace.svelte.ts` — `openSurface(kind, params, placement?)`; `reconcileSessions(running)`; persist the Sessions space; drop `rail`/`side` from `Space`.
- `frontend/src/lib/shell/workspace-persistence.ts` — drop `rail`/`side` from `SpaceSnapshot`; bump `WORKSPACE_SCHEMA`.
- `frontend/src/lib/components/shell/TileGrid.svelte` — external-drop mode (`onExternalDrop` prop + dockDrag highlight/commit).
- `frontend/src/lib/components/shell/LegendShell.svelte` — render `Dock` + active grid; remove per-space rail/side branching; wire `onExternalDrop` + `reconcileSessions`; update empty captions.
- `frontend/src/lib/components/library/FileSurface.svelte` — in-tile Details toggle (`SidePane`).
- `frontend/src/lib/components/surfaces/SessionSurface.svelte` — in-tile Details toggle (`SidePane`).

**Retired (git rm after relocation)**
- `frontend/src/lib/components/sessions/SessionBench.svelte` (→ `SessionsSource`).
- `frontend/src/lib/components/library/LibraryRail.svelte` (→ `FilesSource`).
- `frontend/src/lib/components/library/LibrarySide.svelte` (Details → per-tile).

---

## Task 1: workspaceStore — placement, sessions reconcile, persist Sessions space

**Files:**
- Modify: `frontend/src/lib/shell/tiling-core.ts`
- Test: `frontend/src/lib/shell/tiling-core.test.ts`
- Modify: `frontend/src/lib/shell/workspace.svelte.ts`, `frontend/src/lib/shell/workspace-persistence.ts`

**Interfaces:**
- Produces: `unplacedRunning(placed: string[], running: string[]): string[]`; `workspaceStore.openSurface(kind, params, placement?: { targetId: string; side: DropSide })`; `workspaceStore.reconcileSessions(running: string[])`; `Space` without `rail`/`side`.

- [ ] **Step 1: Write the failing test for `unplacedRunning`**

Append to `frontend/src/lib/shell/tiling-core.test.ts`:
```ts
import { unplacedRunning } from './tiling-core';

describe('unplacedRunning', () => {
	it('returns running ids not already placed, preserving running order', () => {
		expect(unplacedRunning(['a'], ['a', 'b', 'c'])).toEqual(['b', 'c']);
	});
	it('returns empty when all running are placed', () => {
		expect(unplacedRunning(['a', 'b'], ['a', 'b'])).toEqual([]);
	});
	it('ignores placed ids that are not running', () => {
		expect(unplacedRunning(['x', 'y'], ['a'])).toEqual(['a']);
	});
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `cd frontend && bun run test`
Expected: FAIL — `unplacedRunning` not exported.

- [ ] **Step 3: Implement `unplacedRunning` in `tiling-core.ts`**

Append to `frontend/src/lib/shell/tiling-core.ts`:
```ts
/** Running ids that are not already placed somewhere (running order preserved). */
export function unplacedRunning(placed: string[], running: string[]): string[] {
	const have = new Set(placed);
	return running.filter((id) => !have.has(id));
}
```

- [ ] **Step 4: Run it; verify it passes**

Run: `cd frontend && bun run test`
Expected: PASS (all `tiling-core` tests, including the 3 new).

- [ ] **Step 5: Add `placement` to `openSurface`**

In `frontend/src/lib/shell/workspace.svelte.ts`, import `DropSide`:
```ts
import type { DropSide } from './tiling-core';
```
Replace the `openSurface` + `#addOrFocus` methods with:
```ts
	/** Open a surface into the active space, routing off the auto Sessions space.
	 *  `placement` (from a dock drag) inserts the new tile relative to a target. */
	openSurface(
		kind: string,
		params: Record<string, unknown>,
		placement?: { targetId: string; side: DropSide }
	): void {
		if (this.active.auto) {
			if (kind === 'session') {
				sessionsLayout.promote(params.sessionId as string);
				return;
			}
			this.switchSpace(kind === 'file' ? 'library' : this.#ensureCustom());
		}
		this.#addOrFocus(this.active, kind, params, placement);
		if (kind === 'file') void filesStore.load(params.path as string);
	}

	#addOrFocus(
		space: Space,
		kind: string,
		params: Record<string, unknown>,
		placement?: { targetId: string; side: DropSide }
	): void {
		const k = SURFACES[kind]?.key?.(params);
		if (k) {
			const existing = space.layout.tiles.find((id) => {
				const b = this.#bindings[id];
				return b && b.kind === kind && SURFACES[kind].key!(b.params) === k;
			});
			if (existing) {
				space.layout.setActive(existing);
				return;
			}
		}
		const id = this.#mint();
		this.#bindings[id] = { kind, params };
		space.layout.add(id);
		// Precise placement from a drag: move the new tile next to the target.
		if (placement && placement.targetId !== id && space.layout.has(placement.targetId)) {
			space.layout.dropRelative(id, placement.targetId, placement.side);
		}
	}
```

- [ ] **Step 6: Add restore-preserving session reconcile (dismiss + cap kept)**

First, in `frontend/src/lib/shell/sessions-layout.svelte.ts` add two methods to the `SessionsLayout` class (it already has `#dismissed`, `MAX_TILES`, `dismissedIds()`, `layout`):
```ts
	isDismissed(id: string): boolean {
		return this.#dismissed.has(id);
	}
	/** Auto-append a session tile to the Sessions space, respecting dismiss + cap.
	 *  Does NOT clear the dismissed flag (unlike promote). */
	autoAdd(id: string): void {
		if (this.#dismissed.has(id) || this.layout.has(id)) return;
		if (this.layout.tileCount >= MAX_TILES) return; // at cap: leave it in the dock
		this.layout.add(id);
	}
```
(`#dismissed` is the reactive `SvelteSet` from the persistence follow-up; `.has` is reactive — fine.)

Then in `workspace.svelte.ts` add `reconcileSessions` (after `switchSpace`), importing `unplacedRunning` from `./tiling-core`:
```ts
	/** Restore-preserving reconcile: prune Sessions-space tiles whose session no
	 *  longer exists, then auto-append live sessions not placed in ANY space and
	 *  not user-dismissed. The restored layout is otherwise left intact. */
	reconcileSessions(live: string[]): void {
		const liveSet = new Set(live);
		const placed = this.spaces.flatMap((s) =>
			s.layout.tiles
				.filter((id) => this.binding(id)?.kind === 'session')
				.map((id) => this.binding(id)!.params.sessionId as string)
		);
		const sess = this.#sessionsSpace;
		for (const id of [...sess.layout.tiles]) {
			if (this.binding(id)?.kind === 'session' && !liveSet.has(id)) sess.layout.remove(id);
		}
		for (const id of unplacedRunning(placed, live)) sessionsLayout.autoAdd(id);
	}
```
The shell passes ALL session ids (running + stopped) from `sessionsStore.sessions` as `live`: deleted sessions (absent) get pruned; stopped ones stay as resume tiles; brand-new ones auto-append (unless dismissed or placed elsewhere or at cap). This preserves the watch-set's dismiss + cap behavior while honoring the restored layout. The old `sessionsLayout.reconcile`/`promote`-on-mount call in the shell is replaced by this in Task 5.

- [ ] **Step 7: Persist the Sessions space (remove the marker special-case)**

In `workspace.svelte.ts` `snapshot()`, replace the whole `this.spaces.map(...)` body so EVERY space (including `auto`) serializes its real layout + bindings:
```ts
		const spaces = this.spaces.map((space) => {
			const bindings = space.layout.tiles
				.map((id) => {
					const b = this.binding(id);
					return b ? { id, kind: b.kind, params: b.params } : { id, kind: '', params: {} };
				})
				.filter((b) => b.kind);
			return {
				id: space.id,
				name: space.name,
				auto: space.auto,
				layout: space.layout.serialize(),
				bindings
			};
		});
```
(Uses `this.binding(id)` so session tiles in the auto space serialize as `{kind:'session', params:{sessionId}}`.)

In `hydrate()`, the `entry.auto === 'sessions'` branch must now RESTORE the sessions layout (not just keep the empty live space). Replace that branch:
```ts
				if (entry.auto === 'sessions') {
					noteSeq(entry.id, 'space-');
					// restore the auto space's saved layout onto the live sessionsLayout
					live.layout.deserialize(entry.layout);
					for (const b of entry.bindings) {
						// session tiles are derived; nothing to put in #bindings
					}
					return live;
				}
```
Remove the now-unused `rail`/`side` reads in the non-auto branch and in the returned `Space` object (see Task 5 for the `Space` shape change). For now keep the file compiling; Task 5 removes `rail`/`side` everywhere.

- [ ] **Step 8: Drop `rail`/`side` from the snapshot schema + bump version**

In `frontend/src/lib/shell/workspace-persistence.ts`: remove `rail?` and `side?` from `SpaceSnapshot`; set `export const WORKSPACE_SCHEMA = 2;`.

- [ ] **Step 9: Verify + commit**

Run: `cd frontend && bun run check && bun run test && bun run build`
Expected: 0/0; tests pass; build ok. (If `rail`/`side` references in `workspace.svelte.ts` snapshot/hydrate now error, delete them — they are removed in Task 5 anyway.)
```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/shell/tiling-core.ts frontend/src/lib/shell/tiling-core.test.ts frontend/src/lib/shell/workspace.svelte.ts frontend/src/lib/shell/workspace-persistence.ts
git commit -m "feat(dock): openSurface placement + restore-and-append session reconcile + persist all spaces"
```

---

## Task 2: dock→grid drag state + `TileGrid` external-drop

**Files:**
- Create: `frontend/src/lib/shell/dock-drag.svelte.ts`
- Modify: `frontend/src/lib/components/shell/TileGrid.svelte`

**Interfaces:**
- Produces: `dockDrag` singleton (`payload`, `x`, `y`, `start(e, payload)`, `setDropTarget(fn): () => void`); `DockDragPayload = { kind: string; params: Record<string, unknown>; label: string }`. `TileGrid` new prop `onExternalDrop?: (payload: DockDragPayload, placement?: { targetId: string; side: DropSide }) => void`.

- [ ] **Step 1: Create `dock-drag.svelte.ts`**
```ts
// A drag that starts in the Dock and drops into the active TileGrid. The dock
// row calls start(); the grid registers a drop target and reads payload/x/y to
// render drop zones. Pointer-based to match TileGrid's intra-grid re-tiling.
export interface DockDragPayload {
	kind: string;
	params: Record<string, unknown>;
	label: string;
}

class DockDrag {
	payload = $state<DockDragPayload | null>(null);
	x = $state(0);
	y = $state(0);
	#drop: ((p: DockDragPayload, x: number, y: number) => void) | null = null;

	/** The active grid registers itself; returns an unregister fn. */
	setDropTarget(fn: (p: DockDragPayload, x: number, y: number) => void): () => void {
		this.#drop = fn;
		return () => {
			if (this.#drop === fn) this.#drop = null;
		};
	}

	start(e: PointerEvent, payload: DockDragPayload): void {
		if (e.button !== 0) return;
		const sx = e.clientX;
		const sy = e.clientY;
		let active = false;
		const move = (ev: PointerEvent) => {
			if (!active) {
				if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
				active = true;
				document.body.style.userSelect = 'none';
				this.payload = payload;
			}
			this.x = ev.clientX;
			this.y = ev.clientY;
		};
		const up = (ev: PointerEvent) => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			window.removeEventListener('pointercancel', up);
			document.body.style.userSelect = '';
			if (active && this.payload) this.#drop?.(this.payload, ev.clientX, ev.clientY);
			this.payload = null;
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}
}

export const dockDrag = new DockDrag();
```

- [ ] **Step 2: Add external-drop to `TileGrid.svelte`**

Add the prop + import (`dockDrag`, `DockDragPayload`). In the props block add:
```ts
		onExternalDrop
	}: {
		layout: TileLayout;
		tile: Snippet<[string, (e: PointerEvent) => void]>;
		empty?: Snippet;
		dragLabel?: (id: string) => string;
		minColPx?: number;
		minRowPx?: number;
		onExternalDrop?: (
			payload: import('$lib/shell/dock-drag.svelte').DockDragPayload,
			placement?: { targetId: string; side: DropSide }
		) => void;
	} = $props();
```
Add import at top: `import { dockDrag } from '$lib/shell/dock-drag.svelte';`

Add a derived external-drop target + register the drop handler:
```ts
	// External (dock) drag: highlight the i3 zone under the pointer; commit on drop.
	const extDrop = $derived(
		dockDrag.payload && host ? hitTestPoint(dockDrag.x, dockDrag.y) : null
	);
	function hitTestPoint(x: number, y: number): { id: string; side: DropSide } | null {
		return hitTest(x, y, '__none__');
	}
	$effect(() => {
		if (!onExternalDrop) return;
		return dockDrag.setDropTarget((payload, x, y) => {
			if (!host) return;
			const r = host.getBoundingClientRect();
			if (x < r.left || x > r.right || y < r.top || y > r.bottom) return; // dropped outside
			const t = hitTest(x, y, '__none__');
			onExternalDrop(payload, t ? { targetId: t.id, side: t.side } : undefined);
		});
	});
```
(`hitTest` already skips a `draggedId`; passing `'__none__'` excludes nothing.)

In the template, render the external-drop highlight (same `sideClass` overlay) on the `extDrop` target tile, and an external ghost. Inside the `{#each tiles}` block, after the existing intra-grid `drop` highlight, add:
```svelte
					{#if extDrop && extDrop.id === id}
						<div
							class="pointer-events-none absolute z-30 {sideClass[extDrop.side]}"
							style:background="var(--accent-soft)"
							style:outline="2px solid var(--accent)"
							style:outline-offset="-2px"
						></div>
					{/if}
```
After the intra-grid ghost block, add an external ghost:
```svelte
		{#if dockDrag.payload}
			<div
				class="pointer-events-none fixed z-[100] flex -translate-x-1/2 -translate-y-[150%] items-center gap-1.5 rounded-[8px] border border-hair-strong bg-raised px-2.5 py-1 text-ui text-ink-1 shadow-drag"
				style:left="{dockDrag.x}px"
				style:top="{dockDrag.y}px"
			>
				{dockDrag.payload.label}
			</div>
		{/if}
```
Also: when `tiles.length === 0`, the external-drop should still work (drop into an empty grid → append). The `{#if tiles.length === 0}` branch renders `empty`; ensure the host still registers the drop target (the `$effect` runs regardless) and the empty branch doesn't block pointer events. Add the external ghost rendering outside the `{#if tiles.length}` guard so it shows during an empty-grid drop too — move the `{#if dockDrag.payload}` ghost block to just before the closing `</div>` of the host, outside the `{:else}`.

- [ ] **Step 3: Verify + commit**

Run: `cd frontend && bun run check && bun run test && bun run build` (0/0, pass, ok). `onExternalDrop` is unused until Task 5 wires it; this verifies compilation.
```bash
git add frontend/src/lib/shell/dock-drag.svelte.ts frontend/src/lib/components/shell/TileGrid.svelte
git commit -m "feat(dock): dockDrag state + TileGrid external-drop (zones + commit)"
```

---

## Task 3: FilesSource + SessionsSource (relocate rails into draggable dock sections)

**Files:**
- Create: `frontend/src/lib/components/shell/sources/FilesSource.svelte`
- Create: `frontend/src/lib/components/shell/sources/SessionsSource.svelte`
- Modify: `frontend/src/lib/components/library/LibraryTree.svelte` (add an optional row-drag hook)

**Interfaces:**
- Consumes: `dockDrag.start` (Task 2), `workspaceStore.openSurface`/`activePath`/`active` (Task 1), `libraryStore`, `sessionsStore`, `liveState`, `messagesStore.unreadCount`, `filterTree`, `writeFile`, `LibraryTree`.
- Produces: `FilesSource`, `SessionsSource` (prop-less; read stores).

- [ ] **Step 1: Add a drag hook to `LibraryTree.svelte`**

In `frontend/src/lib/components/library/LibraryTree.svelte`, add an optional prop `ondragstart?: (path: string, e: PointerEvent) => void` to the props block, and on the **file** button (the `{:else}` branch button) add `onpointerdown={(e) => ondragstart?.(n.path, e)}`. Leave the existing `onclick={() => onselect(n.path)}` intact. (Folder rows are not draggable.) Verify `bun run check` stays 0/0.

- [ ] **Step 2: Create `FilesSource.svelte`** — relocate the body of `frontend/src/lib/components/library/LibraryRail.svelte` VERBATIM (the Explorer header: filter toggle + file count + the "＋ new file" Popover; and `<LibraryTree>`), with these changes:
  - `onselect` → `(p) => workspaceStore.openSurface('file', { path: p })` (open into the ACTIVE space, not the Library-only `openFile`).
  - Pass `ondragstart={(p, e) => dockDrag.start(e, { kind: 'file', params: { path: p }, label: p.split('/').at(-1) ?? p })}` to `<LibraryTree>`.
  - The new-file flow stays: `writeFile(path, '')` → `libraryStore.refresh()` → `workspaceStore.openSurface('file', { path })`.
  - Keep the dirty-dot (`filesStore.openPaths().find((p) => filesStore.dirty(p))`) and `selected={workspaceStore.activePath}`.
  - Imports: `dockDrag` from `$lib/shell/dock-drag.svelte`, `workspaceStore`, `filesStore`, `libraryStore`, `filterTree`, `writeFile` from `$lib/library`, `LibraryTree`, `IconButton`, `Popover`, `SectionLabel`, `Button`, `Icon`. Root: `class="flex h-full flex-col"` (no width — the Dock owns width).

- [ ] **Step 3: Create `SessionsSource.svelte`** — relocate the grouping/row logic of `frontend/src/lib/components/sessions/SessionBench.svelte` VERBATIM, with these changes:
  - Groups: keep **Needs you** / **Running** / **Idle** (by `liveState`); **DROP the "Watching" group** (placement is per-space now). Group predicates: needs = `state.attention`; running = `state.kind === 'running' && !state.attention`; idle = `(state.kind === 'idle' || state.kind === 'done') && !state.attention`.
  - Row `onclick` → `workspaceStore.openSurface('session', { sessionId: s.id, name: s.name || s.harness_id })` (was `sessionsLayout.promote`).
  - Row `onpointerdown` → `dockDrag.start(e, { kind: 'session', params: { sessionId: s.id, name: s.name || s.harness_id }, label: s.name || s.harness_id })`.
  - "Open here" marker: replace the old `row.watching` accent spine/bg with `placed = workspaceStore.active.layout.has(s.id) || workspaceStore.active.layout.tiles.some((t) => workspaceStore.binding(t)?.kind==='session' && workspaceStore.binding(t)?.params.sessionId===s.id)` — show the accent spine/`bg-[var(--accent-soft)]` when `placed`.
  - Keep `StatusDot`, the harness identity tag (if present), unread badge (`messagesStore.unreadCount(s.id)`), the `state.flag` (ERR/ASK), and the filter input.
  - Imports: `dockDrag`, `workspaceStore`, `sessionsStore`, `messagesStore`, `liveState` from `$lib/shell/sessionState`, `Icon`, `IconButton`, `StatusDot`, types. Root: `class="flex h-full flex-col"`.

- [ ] **Step 4: Verify + commit**

Run: `cd frontend && bun run check && bun run test && bun run build` (0/0, pass, ok). The sources are unused until Task 4; this verifies they compile against the real store/component APIs. Fix any prop-name mismatch against the actual `LibraryRail`/`SessionBench` source.
```bash
git add frontend/src/lib/components/shell/sources frontend/src/lib/components/library/LibraryTree.svelte
git commit -m "feat(dock): FilesSource + SessionsSource (draggable, click-to-open dock sections)"
```

---

## Task 4: `DockSource` contract + `Dock.svelte`

**Files:**
- Create: `frontend/src/lib/shell/dock-sources.ts`
- Create: `frontend/src/lib/components/shell/Dock.svelte`

**Interfaces:**
- Consumes: `FilesSource`, `SessionsSource` (Task 3).
- Produces: `DockSource = { id: string; label: string; icon: IconName; component: Component }`, `DOCK_SOURCES: DockSource[]`; `Dock` component (prop-less).

- [ ] **Step 1: Create `dock-sources.ts`**
```ts
import type { Component } from 'svelte';
import type { IconName } from '$lib/components/shell/Icon.svelte';
import FilesSource from '$lib/components/shell/sources/FilesSource.svelte';
import SessionsSource from '$lib/components/shell/sources/SessionsSource.svelte';

export interface DockSource {
	id: string;
	label: string;
	icon: IconName;
	component: Component;
}

export const DOCK_SOURCES: DockSource[] = [
	{ id: 'sessions', label: 'Sessions', icon: 'sessions', component: SessionsSource },
	{ id: 'files', label: 'Files', icon: 'folder', component: FilesSource }
];
```

- [ ] **Step 2: Create `Dock.svelte`** — a persistent left panel rendering `DOCK_SOURCES` as collapsible accordion sections, with a whole-dock collapse. Persist collapse state to `localStorage` (`legend:dock`) guarded in `onMount`/`$effect`.
```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import Icon from './Icon.svelte';
	import IconButton from './IconButton.svelte';
	import { DOCK_SOURCES } from '$lib/shell/dock-sources';

	let collapsed = $state(false); // whole dock
	let openSections = $state<Record<string, boolean>>(
		Object.fromEntries(DOCK_SOURCES.map((s) => [s.id, true]))
	);
	let hydrated = $state(false);

	onMount(() => {
		try {
			const raw = localStorage.getItem('legend:dock');
			if (raw) {
				const v = JSON.parse(raw);
				if (typeof v.collapsed === 'boolean') collapsed = v.collapsed;
				if (v.openSections) openSections = { ...openSections, ...v.openSections };
			}
		} catch {
			/* ignore corrupt */
		}
		hydrated = true;
	});
	$effect(() => {
		if (!hydrated) return;
		try {
			localStorage.setItem('legend:dock', JSON.stringify({ collapsed, openSections }));
		} catch {
			/* non-fatal */
		}
	});
</script>

{#if collapsed}
	<div class="flex w-9 shrink-0 flex-col items-center gap-2 border-r border-hair bg-shell pt-2.5">
		<IconButton icon="panel-right" title="Expand dock" onclick={() => (collapsed = false)} />
		{#each DOCK_SOURCES as s (s.id)}
			<IconButton icon={s.icon} title={s.label} onclick={() => { collapsed = false; openSections[s.id] = true; }} />
		{/each}
	</div>
{:else}
	<div class="flex w-[210px] shrink-0 flex-col border-r border-hair bg-shell">
		<div class="flex h-[var(--h-bar)] shrink-0 items-center justify-between border-b border-hair pl-3 pr-1.5">
			<span class="text-ui font-semibold text-ink-2">Sources</span>
			<IconButton icon="panel-right" title="Collapse dock" onclick={() => (collapsed = true)} />
		</div>
		<div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
			{#each DOCK_SOURCES as s (s.id)}
				{@const Section = s.component}
				<div class="flex min-h-0 flex-col border-b border-hair last:border-b-0" class:flex-1={openSections[s.id]}>
					<button
						type="button"
						onclick={() => (openSections[s.id] = !openSections[s.id])}
						class="flex h-[var(--h-row)] shrink-0 items-center gap-1.5 px-2.5 text-left"
					>
						<Icon name={openSections[s.id] ? 'chevron-down' : 'chevron-right'} size={12} class="text-ink-3" />
						<Icon name={s.icon} size={13} class="text-ink-3" />
						<span class="font-mono text-micro font-semibold uppercase tracking-[0.14em] text-ink-3">{s.label}</span>
					</button>
					{#if openSections[s.id]}
						<div class="min-h-0 flex-1 overflow-y-auto"><Section /></div>
					{/if}
				</div>
			{/each}
		</div>
	</div>
{/if}
```
(If `panel-right` reads oddly for collapse both ways, use `panel-right` for collapse and `panel-right` again for expand — both exist; keep one glyph. Token discipline: only Legend tokens used above.)

- [ ] **Step 3: Verify + commit**

Run: `cd frontend && bun run check && bun run test && bun run build` (0/0, pass, ok). Dock is unused until Task 5.
```bash
git add frontend/src/lib/shell/dock-sources.ts frontend/src/lib/components/shell/Dock.svelte
git commit -m "feat(dock): DockSource registry + persistent collapsible Dock shell"
```

---

## Task 5: Shell restructure — render Dock + uniform grid; retire rails/side

**Files:**
- Modify: `frontend/src/lib/components/shell/LegendShell.svelte`, `frontend/src/lib/shell/workspace.svelte.ts`
- Delete (git rm): `frontend/src/lib/components/sessions/SessionBench.svelte`, `frontend/src/lib/components/library/LibraryRail.svelte`, `frontend/src/lib/components/library/LibrarySide.svelte`

**Interfaces:** Consumes `Dock` (Task 4), `TileGrid.onExternalDrop` (Task 2), `workspaceStore.reconcileSessions`/`openSurface` (Task 1).

- [ ] **Step 1: Drop `rail`/`side` from `Space`** in `workspace.svelte.ts`: remove `rail?`/`side?` from the `Space` interface and from the seeded `library` space (`{ id:'library', name:'Library', icon:'folder', layout: new TileLayout() }`); remove any remaining `rail`/`side` reads in `snapshot`/`hydrate` (the `library`-icon synthesis in hydrate becomes `icon: 'folder'` for the seeded id, else `'grid'` — or just default `'grid'` and special-case nothing since icon now persists; simplest: persist `icon` in the snapshot too — add `icon` to `SpaceSnapshot` and restore it). Update `SpaceSnapshot` (persistence) to carry `icon: IconName` and drop `rail`/`side` (already bumped to schema 2 in Task 1).

- [ ] **Step 2: Rewrite the body of `LegendShell.svelte`** — replace the 3-frame branching (`{#if space.auto}…{:else if space.rail}…{:else}…`) with a single uniform render: the `Dock` + the active space's `TileGrid`. Replace imports: remove `SessionBench`, `LibraryRail`, `LibrarySide`, `WorkbenchLayout`; add `import Dock from './Dock.svelte';`. The body row becomes:
```svelte
	<div class="flex min-h-0 flex-1">
		<Dock />
		<div class="min-w-0 flex-1 overflow-hidden bg-app">
			<TileGrid
				layout={space.layout}
				dragLabel={(id) => workspaceStore.dragLabel(id)}
				onExternalDrop={(p, placement) => workspaceStore.openSurface(p.kind, p.params, placement)}
			>
				{#snippet tile(id, grab)}{@render surfaceTile(id, grab)}{/snippet}
				{#snippet empty()}{@render emptyState()}{/snippet}
			</TileGrid>
		</div>
	</div>
```
Keep the `surfaceTile` snippet. Collapse the three `*Empty` snippets into ONE `emptyState` snippet that renders `<AsteroidsGame>` with a dock-pointing caption:
```svelte
	{#snippet emptyState()}
		<AsteroidsGame>
			<p class="text-ui text-ink-2">This space is empty.</p>
			<p class="max-w-[320px] text-meta text-ink-3">Click or drag a file or session from the dock on the left to open it here.</p>
		</AsteroidsGame>
	{/snippet}
```

- [ ] **Step 3: Replace the reconcile effect.** Remove the `candidates` `$derived.by(...)` ranking and the `sessionsLayout.reconcile(candidates)` `$effect`. Replace with:
```ts
	const liveSessionIds = $derived(sessionsStore.sessions.map((s) => s.id));
	$effect(() => {
		workspaceStore.reconcileSessions(liveSessionIds);
	});
```
Keep the existing `connect()` effect, the persistence hydrate/save effects, and the keyboard handler — but in the keyboard handler, the session-keys gate `space.auto !== 'sessions'` stays valid (the Sessions space still has `auto:'sessions'`). `liveState` import may now be unused → remove if so.

- [ ] **Step 4: Delete the retired rails**
```bash
cd /Users/daniel/Development/legend
git rm frontend/src/lib/components/sessions/SessionBench.svelte frontend/src/lib/components/library/LibraryRail.svelte frontend/src/lib/components/library/LibrarySide.svelte
```
Then `grep -rn "SessionBench\|LibraryRail\|LibrarySide\|WorkbenchLayout" frontend/src` — fix/remove any remaining importers (`WorkbenchLayout` should now be unreferenced; leave the file, or `git rm` it if you confirm zero importers).

- [ ] **Step 5: Verify**

Run: `cd frontend && bun run check && bun run test && bun run build` (0/0, pass, ok) and `grep` is clean.

- [ ] **Step 6: PARITY RE-CHECK (controller).** With `just dev`, confirm via the live click-through: the dock shows Sessions + Files in every space; clicking a session/file opens it in the active space; dragging a dock item onto a tile's edge places it; the Sessions space still shows running agents on load (auto-append); reload restores spaces + tiles. The implementer reports check/build/test; the controller runs the browser check.

- [ ] **Step 7: Commit**
```bash
git add -A frontend/src
git commit -m "feat(dock): render Dock + uniform grid; retire per-space rails/side"
```

---

## Task 6: Per-tile Details (in-window SidePane)

**Files:**
- Modify: `frontend/src/lib/components/library/FileSurface.svelte`, `frontend/src/lib/components/surfaces/SessionSurface.svelte`

**Interfaces:** Consumes `SidePane`/`SidePaneSection`/`SidePaneField`, `IconButton`, `libraryStore.entries`, `sessionsStore`, `relativeTime`/`formatBytes`.

- [ ] **Step 1: `FileSurface` Details toggle.** Add `let detailsOpen = $state(false);` and a header `IconButton` (`icon="panel-right"`, `active={detailsOpen}`, `tone="accent"`, title "Details", `onclick={() => (detailsOpen = !detailsOpen)}`) next to the existing Split/⋯ controls. In the body, wrap the textarea + an optional right panel in a flex row:
```svelte
	<div class="flex min-h-0 flex-1">
		<div class="min-w-0 flex-1">{<!-- existing textarea / empty state --> }</div>
		{#if detailsOpen && path}
			{@const e = libraryStore.entries.find((x) => x.path === path)}
			<div class="w-[260px] shrink-0 border-l border-hair">
				<SidePane title="Details" icon="file">
					{#if e}
						<SidePaneSection label="File">
							<SidePaneField label="Type" value={e.type === 'dir' ? 'Folder' : 'Document'} />
							<SidePaneField label="Size" value={formatBytes(e.size)} />
							<SidePaneField label="Modified" value={relativeTime(e.mtime) || '—'} />
							<SidePaneField label="Path" value={e.path} />
						</SidePaneSection>
					{/if}
					{#snippet footer()}
						<Button size="sm" variant="outline" class="h-8 w-full text-meta" onclick={() => navigator.clipboard?.writeText(path)}>
							<Icon name="link" size={13} class="mr-1.5" /> Copy reference
						</Button>
					{/snippet}
				</SidePane>
			</div>
		{/if}
	</div>
```
(Reuse the retired `LibrarySide` content. `SidePane`'s `onClose` is optional — omit, or pass `onClose={() => (detailsOpen = false)}`.)

- [ ] **Step 2: `SessionSurface` Details toggle.** Same pattern — add a Details toggle to its header (it currently just wraps `SessionPane`; add the toggle by passing a header action OR wrapping). Since `SessionSurface` delegates the header to `SessionPane`, add the Details toggle inside `SessionPane`'s header (a `panel-right` IconButton) gated to when rendered as a surface — simplest: add `detailsOpen` state in `SessionPane` and an in-pane right `SidePane` showing session fields (`session.name`, `harness_id`, runtime if available, `session.cwd`, `liveState(session).label`, and `spawned_by_session_id` lineage). Render the `SidePane` to the right of the terminal body in a flex row, toggled by the header button. Use `SidePaneField` for each fact.

- [ ] **Step 3: Verify + commit**

Run: `cd frontend && bun run check && bun run test && bun run build` (0/0, pass, ok).
```bash
git add frontend/src/lib/components/library/FileSurface.svelte frontend/src/lib/components/sessions/SessionPane.svelte frontend/src/lib/components/surfaces/SessionSurface.svelte
git commit -m "feat(dock): per-tile in-window Details panel (file + session)"
```

---

## Task 7: Docs

**Files:** Modify `docs/ARCHITECTURE.md`, `docs/DESIGN_SYSTEM.md`, `docs/VISION.md`.

- [ ] **Step 1:** `ARCHITECTURE.md` — add the source dock: the `Dock` + `DockSource` registry; the `dockDrag` → `TileGrid.onExternalDrop` protocol (pointer-based, reuses i3 hit-testing); uniform grid spaces (per-space rails retired); per-tile Details (in-window `SidePane`); restore-last-state + `reconcileSessions` (append-unplaced-running, dismiss + cap preserved); `openSurface(kind, params, placement?)`.
- [ ] **Step 2:** `DESIGN_SYSTEM.md` — `Dock` as a first-class shell primitive; note `SidePane` is now also used in-tile (per-surface Details).
- [ ] **Step 3:** `VISION.md` — sources are pluggable like surfaces ("pull content from the dock into the workspace; drag to tile").
- [ ] **Step 4: Verify + commit** — `cd frontend && bun run check` (docs-only, stays 0/0); `git add docs && git commit -m "docs: source dock (dock + drag-to-tile + per-tile details + uniform spaces)"`.

---

## Self-Review

**Spec coverage:** Dock + `DockSource` (T4) ✓; Files/Sessions sources (T3) ✓; click + pointer drag with i3 placement (T2 dockDrag + TileGrid external-drop, T1 openSurface placement) ✓; uniform grid spaces, rails retired (T5) ✓; per-tile Details via in-window SidePane (T6) ✓; restore-last-state incl. Sessions space + auto-append running + tolerant tiles (T1) ✓; docs (T7) ✓. Non-goals respected (no new surface kinds, no backend/sync, no OS windows).

**Placeholder scan:** No TBD/TODO. Relocation tasks (T3, T5, T6) reference exact source files to copy from and the precise changes; the novel pieces (dockDrag, TileGrid external-drop, openSurface placement, reconcileSessions, DockSource, Dock) have complete code. Component tasks verify via check/build (no component runner); the pure helper (`unplacedRunning`) is unit-tested.

**Type consistency:** `DockDragPayload { kind, params, label }` is produced in T2 and consumed by the sources (T3) + `TileGrid.onExternalDrop` (T2) + the shell's `onExternalDrop` wiring (T5). `openSurface(kind, params, placement?)` signature is defined in T1 and used by the sources' click (T3, no placement), the external-drop commit (T5, with placement). `reconcileSessions(live)` defined T1, called T5. `DockSource`/`DOCK_SOURCES` defined T4, used by `Dock` (T4). `Space` loses `rail`/`side` in T5; `SpaceSnapshot` loses them + gains `icon` and `WORKSPACE_SCHEMA=2` (T1 bump + T5 icon). `sessionsLayout.autoAdd`/`isDismissed` defined T1, used by `reconcileSessions` (T1).

