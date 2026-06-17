# Tiling Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tiling the windowing core of the app — a content-agnostic `TileLayout` + flat-positioned `TileGrid` — and run both Sessions and Library on it (Phase 1), then build the Space/launcher/modal OS workspace on top (Phase 2).

**Architecture:** Extract today's session-only tiling (`watchset.svelte.ts` + `WatchSetGrid.svelte`) into a generic windowing primitive that deals in opaque tile ids. Render every tile once in a flat absolutely-positioned layer (rects computed from the layout tree) so a tile's component — and the xterm inside it — never unmounts on re-tile. Sessions migrates onto the primitive (parity); Library gains split-on-demand file editing on the same primitive.

**Tech Stack:** SvelteKit 2 SPA (`ssr=false`), Svelte 5 runes, TypeScript, Tailwind v4 + Legend design tokens, Vitest (new, for pure logic), Bun.

**Spec:** `docs/superpowers/specs/2026-06-17-tiling-workspace-design.md`

## Global Constraints

- Frontend only (`frontend/`). No backend/Elixir changes. No new backend endpoints.
- Svelte 5 runes only (`$state`/`$derived`/`$props`/`$bindable`, snippets). No stores-as-observables.
- Design tokens only: `text-ink-1/2/3`, `bg-shell/app/panel/raised/inset`, `border-hair`/`border-hair-strong`, `text-brand/brand-hi`, `bg-[var(--accent-soft)]`, `text-ok/warn/bad`, type scale `text-micro/meta/ui/body/title`, `--h-bar`/`--h-row`. Never raw shadcn neutral classes, ad-hoc hex, or ad-hoc `text-[Npx]`. shadcn semantic classes appear only under `src/lib/components/ui/`.
- Never `window.confirm`/`alert`/`prompt` (Tauri webview no-ops them) — in-UI confirmation only (two-step buttons or a dialog).
- No `window`/`localStorage`/`document` access at module top level (SSR-safe even though `ssr=false`); guard inside `onMount`/handlers/`$effect`.
- `bun run check` (svelte-check) must report **0 errors, 0 warnings**; `bun run build` must succeed; `bun run test` (Vitest) must pass.
- The `TileLayout` model has two distinct restore concepts: `restore()` un-zooms focus; `deserialize(snapshot)` loads persisted state. Do not conflate them.
- Tile rendering is **flat positioned** (render-once, never reparent). Do not reintroduce a nested `{#each}` columns→rows DOM tree for tiles — that remounts terminals on cross-column drag.

## Phasing

- **Phase 1 (Tasks 1–5):** windowing core + Sessions parity + Library split-on-demand, rendered through the shell. Ends at a **hard parity checkpoint**. Working software; in-memory spaces (no persistence, no launcher yet).
- **Phase 2 (Tasks 6–11, outlined at end):** surface registry, launcher, modal layer, route collapse, space persistence, docs. Detailed after the Phase 1 checkpoint.

---

## File Structure (Phase 1)

**New:**
- `frontend/src/lib/shell/tiling-core.ts` — pure functions: column-tree ops + `computeRects` + `reconcileColumns`. No runes. Unit-tested.
- `frontend/src/lib/shell/tiling-core.test.ts` — Vitest unit tests for the above.
- `frontend/src/lib/shell/tiling.svelte.ts` — `TileLayout` runes class wrapping the pure core.
- `frontend/src/lib/components/shell/TileGrid.svelte` — generic flat-positioned grid view.
- `frontend/src/lib/shell/sessions-layout.svelte.ts` — `sessionsLayout` (a `TileLayout` + cap/dismiss/reconcile); replaces `watchset.svelte.ts`. Becomes the Sessions space's model in Phase 2.
- `frontend/src/lib/stores/files.svelte.ts` — `filesStore` (path-keyed file buffers).
- `frontend/src/lib/components/library/FileSurface.svelte` — file editor pane (tile content for the Library space).
- `frontend/src/lib/components/library/LibraryRail.svelte` — Library space left rail (filter + tree, reads `workspaceStore`/`filesStore`).
- `frontend/src/lib/components/library/LibrarySide.svelte` — Library space Details side pane.
- `frontend/src/lib/shell/workspace.svelte.ts` — `workspaceStore` (spaces list, active space, Library tile ops). Minimal in Phase 1.
- `frontend/src/lib/components/shell/SpaceSwitcher.svelte` — minimal TopBar space switcher (superseded by the launcher in Phase 2).

**Modified:**
- `frontend/vite.config.ts` — add Vitest `test` config.
- `frontend/package.json` — add `vitest` dev dep + `test` script.
- `frontend/src/lib/components/sessions/SessionPane.svelte` — read `sessionsLayout` instead of `watchSet`.
- `frontend/src/lib/components/sessions/SessionBench.svelte` — read `sessionsLayout` instead of `watchSet`.
- `frontend/src/routes/+page.svelte` — Sessions space renders via `TileGrid` (interim, before the shell hosts spaces in Task 5).
- `frontend/src/lib/components/shell/LegendShell.svelte` — render the active space (rail + `TileGrid` + side) for `sessions`/`library`; mount `SpaceSwitcher`.

**Deleted:**
- `frontend/src/lib/components/sessions/WatchSetGrid.svelte`
- `frontend/src/lib/shell/watchset.svelte.ts`

---

## Task 1: Windowing model — `tiling-core.ts` + `TileLayout` + Vitest

**Files:**
- Create: `frontend/src/lib/shell/tiling-core.ts`
- Test: `frontend/src/lib/shell/tiling-core.test.ts`
- Create: `frontend/src/lib/shell/tiling.svelte.ts`
- Modify: `frontend/vite.config.ts`, `frontend/package.json`

**Interfaces:**
- Produces (consumed by Tasks 2–5):
  - `type DropSide = 'left'|'right'|'top'|'bottom'`
  - `interface Rect { left:number; top:number; width:number; height:number }`
  - `interface LayoutSnapshot { columns:string[][]; colSizes:number[]; rowSizes:number[][]; focusedId:string|null; activeId:string|null }`
  - pure fns: `addColumn`, `removeFrom`, `dropRelative`, `reconcileColumns`, `computeRects`
  - class `TileLayout` with reactive fields `columns/colSizes/rowSizes/focusedId/activeId/draggingId`, getters `tiles`/`tileCount`, methods `has`, `colFlex`, `rowFlex`, `setColSizes`, `setRowSizes`, `rects`, `add`, `remove`, `dropRelative`, `setColumns`, `focus`, `restore`, `setActive`, `startDrag`, `endDrag`, `serialize`, `deserialize`.

- [ ] **Step 1: Install Vitest and add the test script**

Run:
```bash
cd frontend && bun add -d vitest
```
Then in `frontend/package.json` add to `"scripts"` (after `"check:watch"`):
```json
		"test": "vitest run",
		"test:watch": "vitest"
```

- [ ] **Step 2: Configure Vitest in vite.config.ts**

Replace `frontend/vite.config.ts` with:
```ts
import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [tailwindcss(), sveltekit()],
	server: {
		proxy: {
			'/api': 'http://localhost:4100',
			'/socket': { target: 'ws://localhost:4100', ws: true }
		}
	},
	test: {
		// Pure-logic unit tests run in node. Component/runes tests are out of scope
		// for Phase 1; tiling-core.ts imports no runes and no .svelte modules.
		environment: 'node',
		include: ['src/**/*.test.ts']
	}
});
```

- [ ] **Step 3: Write the failing tests for the pure column-tree ops**

Create `frontend/src/lib/shell/tiling-core.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { addColumn, removeFrom, dropRelative, reconcileColumns, computeRects } from './tiling-core';

describe('addColumn', () => {
	it('appends a new right-hand column', () => {
		expect(addColumn([['a']], 'b')).toEqual([['a'], ['b']]);
	});
});

describe('removeFrom', () => {
	it('drops the id and collapses empty columns', () => {
		expect(removeFrom([['a'], ['b']], 'b')).toEqual([['a']]);
		expect(removeFrom([['a', 'b']], 'a')).toEqual([['b']]);
	});
});

describe('dropRelative', () => {
	const cols = () => [['a'], ['b']];
	it('left inserts a new column before the target column', () => {
		expect(dropRelative(cols(), 'a', 'b', 'left')).toEqual([['b'], ['a']]);
	});
	it('right inserts a new column after the target column', () => {
		expect(dropRelative([['a'], ['b'], ['c']], 'a', 'b', 'right')).toEqual([['b'], ['a'], ['c']]);
	});
	it('top stacks above the target within its column', () => {
		expect(dropRelative([['a'], ['b']], 'a', 'b', 'top')).toEqual([['a', 'b']]);
	});
	it('bottom stacks below the target within its column', () => {
		expect(dropRelative([['a'], ['b']], 'a', 'b', 'bottom')).toEqual([['b', 'a']]);
	});
	it('is a no-op when id === targetId', () => {
		expect(dropRelative([['a']], 'a', 'a', 'left')).toEqual([['a']]);
	});
});

describe('reconcileColumns', () => {
	it('keeps live tiles, drops dead ones, fills empties up to max', () => {
		const out = reconcileColumns([['a'], ['dead']], ['a', 'b', 'c'], new Set(), 6);
		expect(out.flat()).toEqual(['a', 'b', 'c']);
	});
	it('never refills a dismissed id', () => {
		const out = reconcileColumns([], ['a', 'b'], new Set(['b']), 6);
		expect(out.flat()).toEqual(['a']);
	});
	it('respects the max tile cap', () => {
		const out = reconcileColumns([], ['a', 'b', 'c'], new Set(), 2);
		expect(out.flat().length).toBe(2);
	});
});

describe('computeRects', () => {
	it('splits width across two equal columns minus the seam', () => {
		const r = computeRects([['a'], ['b']], [], [], 201, 100, 1);
		expect(r.get('a')).toEqual({ left: 0, top: 0, width: 100, height: 100 });
		expect(r.get('b')).toEqual({ left: 101, top: 0, width: 100, height: 100 });
	});
	it('splits a column height across stacked rows minus the seam', () => {
		const r = computeRects([['a', 'b']], [], [], 100, 201, 1);
		expect(r.get('a')).toEqual({ left: 0, top: 0, width: 100, height: 100 });
		expect(r.get('b')).toEqual({ left: 0, top: 101, width: 100, height: 100 });
	});
	it('honors flex weights', () => {
		const r = computeRects([['a'], ['b']], [3, 1], [], 100, 100, 0);
		expect(r.get('a')!.width).toBe(75);
		expect(r.get('b')!.width).toBe(25);
	});
});
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `cd frontend && bun run test`
Expected: FAIL — `tiling-core.ts` does not exist / functions undefined.

- [ ] **Step 5: Implement `tiling-core.ts`**

Create `frontend/src/lib/shell/tiling-core.ts`:
```ts
// Pure windowing-tree logic. No runes, no DOM, no Svelte — fully unit-testable.
// `columns` is left→right; each column is a top→bottom stack of opaque tile ids.

export type DropSide = 'left' | 'right' | 'top' | 'bottom';

export interface Rect {
	left: number;
	top: number;
	width: number;
	height: number;
}

export interface LayoutSnapshot {
	columns: string[][];
	colSizes: number[];
	rowSizes: number[][];
	focusedId: string | null;
	activeId: string | null;
}

export function cloneColumns(cols: string[][]): string[][] {
	return cols.map((c) => [...c]);
}

/** Append `id` as a new right-hand column. */
export function addColumn(cols: string[][], id: string): string[][] {
	return [...cloneColumns(cols), [id]];
}

/** Remove `id` everywhere; drop any column left empty. */
export function removeFrom(cols: string[][], id: string): string[][] {
	return cols.map((c) => c.filter((x) => x !== id)).filter((c) => c.length > 0);
}

/**
 * Re-tile `id` relative to `targetId`. left/right insert a new column beside the
 * target's column; top/bottom split the target's column above/below the target.
 * Reference-based: remove `id` first, then locate the target so removal can't
 * shift it out from under us.
 */
export function dropRelative(
	cols: string[][],
	id: string,
	targetId: string,
	side: DropSide
): string[][] {
	if (id === targetId) return cloneColumns(cols);
	const next = removeFrom(cols, id);
	const ci = next.findIndex((c) => c.includes(targetId));
	if (ci < 0) {
		next.push([id]);
	} else if (side === 'left' || side === 'right') {
		next.splice(side === 'left' ? ci : ci + 1, 0, [id]);
	} else {
		const col = next[ci];
		const ri = col.indexOf(targetId);
		col.splice(side === 'top' ? ri : ri + 1, 0, id);
	}
	return next.filter((c) => c.length > 0);
}

/**
 * Reconcile the column tree against live `candidates`: keep tiles still live (in
 * place), drop tiles no longer live, then append new candidates (in order) up to
 * `max`, skipping any `dismissed` id.
 */
export function reconcileColumns(
	cols: string[][],
	candidates: string[],
	dismissed: Set<string>,
	max: number
): string[][] {
	const live = new Set(candidates);
	const kept = cols.map((c) => c.filter((id) => live.has(id))).filter((c) => c.length > 0);
	const present = new Set(kept.flat());
	let count = present.size;
	for (const id of candidates) {
		if (count >= max) break;
		if (present.has(id) || dismissed.has(id)) continue;
		kept.push([id]);
		present.add(id);
		count++;
	}
	return kept;
}

/**
 * Map each tile id to its pixel rect. Distributes `width` across columns by their
 * flex weight (`colSizes[ci] ?? 1`) minus inter-column seams, then each column's
 * `height` across its rows by weight (`rowSizes[ci][ri] ?? 1`) minus row seams.
 */
export function computeRects(
	columns: string[][],
	colSizes: number[],
	rowSizes: number[][],
	width: number,
	height: number,
	seam: number
): Map<string, Rect> {
	const out = new Map<string, Rect>();
	const nCols = columns.length;
	if (nCols === 0) return out;

	const colWeights = columns.map((_, ci) => colSizes[ci] ?? 1);
	const colWeightSum = colWeights.reduce((a, b) => a + b, 0) || 1;
	const availW = width - seam * (nCols - 1);

	let x = 0;
	columns.forEach((col, ci) => {
		const colW = (availW * colWeights[ci]) / colWeightSum;
		const nRows = col.length;
		const rowWeights = col.map((_, ri) => rowSizes[ci]?.[ri] ?? 1);
		const rowWeightSum = rowWeights.reduce((a, b) => a + b, 0) || 1;
		const availH = height - seam * (nRows - 1);

		let y = 0;
		col.forEach((id, ri) => {
			const rowH = (availH * rowWeights[ri]) / rowWeightSum;
			out.set(id, { left: x, top: y, width: colW, height: rowH });
			y += rowH + seam;
		});
		x += colW + seam;
	});
	return out;
}
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `cd frontend && bun run test`
Expected: PASS — all `tiling-core` tests green.

- [ ] **Step 7: Implement the `TileLayout` runes class**

Create `frontend/src/lib/shell/tiling.svelte.ts`:
```ts
import {
	addColumn,
	cloneColumns,
	computeRects,
	dropRelative,
	removeFrom,
	type DropSide,
	type LayoutSnapshot,
	type Rect
} from './tiling-core';

/**
 * Reactive windowing layout: a tree of opaque tile ids the UI renders. Pure
 * tree math lives in tiling-core.ts; this class is the $state wrapper consumers
 * (TileGrid, sessions-layout, workspaceStore) bind to.
 */
export class TileLayout {
	columns = $state<string[][]>([]);
	/** per-column flex weight (px-derived on resize); empty ⇒ all equal */
	colSizes = $state<number[]>([]);
	/** per-column, per-row flex weight; empty/short ⇒ equal */
	rowSizes = $state<number[][]>([]);
	/** zoom one tile to fill the grid; null ⇒ tiled */
	focusedId = $state<string | null>(null);
	/** highlighted / input-target tile */
	activeId = $state<string | null>(null);
	/** the tile being dragged (drives the drag overlay) */
	draggingId = $state<string | null>(null);

	get tiles(): string[] {
		return this.columns.flat();
	}
	get tileCount(): number {
		return this.tiles.length;
	}
	has(id: string): boolean {
		return this.columns.some((c) => c.includes(id));
	}

	colFlex(ci: number): number {
		return this.colSizes[ci] ?? 1;
	}
	rowFlex(ci: number, ri: number): number {
		return this.rowSizes[ci]?.[ri] ?? 1;
	}
	setColSizes(sizes: number[]): void {
		this.colSizes = sizes;
	}
	setRowSizes(ci: number, sizes: number[]): void {
		const next = this.rowSizes.map((r) => [...r]);
		while (next.length < this.columns.length) next.push([]);
		next[ci] = sizes;
		this.rowSizes = next;
	}

	rects(width: number, height: number, seam = 1): Map<string, Rect> {
		return computeRects(this.columns, this.colSizes, this.rowSizes, width, height, seam);
	}

	/** Assign a new column tree and reset sizes (structure changed ⇒ equalize). */
	setColumns(cols: string[][]): void {
		this.columns = cols;
		this.colSizes = [];
		this.rowSizes = [];
	}

	add(id: string): void {
		if (this.has(id)) {
			this.activeId = id;
			return;
		}
		this.setColumns(addColumn(this.columns, id));
		this.activeId = id;
	}

	remove(id: string): void {
		this.setColumns(removeFrom(this.columns, id));
		if (this.focusedId === id) this.focusedId = null;
		if (this.activeId === id) this.activeId = this.tiles.at(-1) ?? null;
	}

	dropRelative(id: string, targetId: string, side: DropSide): void {
		this.draggingId = null;
		this.setColumns(dropRelative(this.columns, id, targetId, side));
		this.activeId = id;
	}

	focus(id: string): void {
		this.focusedId = id;
		this.activeId = id;
	}
	restore(): void {
		this.focusedId = null;
	}
	setActive(id: string): void {
		this.activeId = id;
	}
	startDrag(id: string): void {
		this.draggingId = id;
	}
	endDrag(): void {
		this.draggingId = null;
	}

	serialize(): LayoutSnapshot {
		return {
			columns: cloneColumns(this.columns),
			colSizes: [...this.colSizes],
			rowSizes: this.rowSizes.map((r) => [...r]),
			focusedId: this.focusedId,
			activeId: this.activeId
		};
	}
	deserialize(snap: LayoutSnapshot): void {
		this.columns = cloneColumns(snap.columns);
		this.colSizes = [...snap.colSizes];
		this.rowSizes = snap.rowSizes.map((r) => [...r]);
		this.focusedId = snap.focusedId;
		this.activeId = snap.activeId;
	}
}
```

- [ ] **Step 8: Verify type-check passes**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 9: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/shell/tiling-core.ts frontend/src/lib/shell/tiling-core.test.ts frontend/src/lib/shell/tiling.svelte.ts frontend/vite.config.ts frontend/package.json frontend/bun.lock
git commit -m "feat(tiling): windowing model — TileLayout + pure tiling-core + Vitest"
```

---

## Task 2: `TileGrid.svelte` + migrate Sessions onto the windowing core

**Files:**
- Create: `frontend/src/lib/components/shell/TileGrid.svelte`
- Create: `frontend/src/lib/shell/sessions-layout.svelte.ts`
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte`
- Modify: `frontend/src/lib/components/sessions/SessionBench.svelte`
- Modify: `frontend/src/routes/+page.svelte`
- Delete: `frontend/src/lib/components/sessions/WatchSetGrid.svelte`, `frontend/src/lib/shell/watchset.svelte.ts`

**Interfaces:**
- Consumes: `TileLayout` (Task 1), `DropSide`/`Rect` (Task 1).
- Produces:
  - `TileGrid` props: `{ layout: TileLayout; tile: Snippet<[id: string, grab: (e: PointerEvent) => void]>; empty?: Snippet; dragLabel?: (id: string) => string; minColPx?: number; minRowPx?: number }`.
  - `sessionsLayout` (singleton) with `.layout: TileLayout`, `isWatching(id)`, `watching: string[]`, `promote(id)`, `evict(id)`, `reconcile(candidates: string[])`, `focus(id)`, `restore()`, `setActive(id)`.

**Verification note:** `TileGrid` and the Svelte components are verified by `bun run check` + `bun run build` + manual click-through (no component test runner in Phase 1). The pure logic they call is already unit-tested in Task 1.

- [ ] **Step 1: Implement `TileGrid.svelte` (flat positioned)**

Create `frontend/src/lib/components/shell/TileGrid.svelte`:
```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import type { DropSide, Rect } from '$lib/shell/tiling-core';

	let {
		layout,
		tile,
		empty,
		dragLabel = (id: string) => id,
		minColPx = 160,
		minRowPx = 90
	}: {
		layout: TileLayout;
		tile: Snippet<[string, (e: PointerEvent) => void]>;
		empty?: Snippet;
		dragLabel?: (id: string) => string;
		minColPx?: number;
		minRowPx?: number;
	} = $props();

	const SEAM = 1;

	let host = $state<HTMLDivElement>();
	let W = $state(0);
	let H = $state(0);

	// Measure the host so rects are pixel-exact (flex weights → px).
	$effect(() => {
		if (!host) return;
		const ro = new ResizeObserver((entries) => {
			const r = entries[0].contentRect;
			W = r.width;
			H = r.height;
		});
		ro.observe(host);
		return () => ro.disconnect();
	});

	const tiles = $derived(layout.tiles);
	const rects = $derived(W > 0 && H > 0 ? layout.rects(W, H, SEAM) : new Map<string, Rect>());

	const full: Rect = $derived({ left: 0, top: 0, width: W, height: H });
	function rectFor(id: string): Rect {
		if (layout.focusedId === id) return full;
		return rects.get(id) ?? { left: 0, top: 0, width: 0, height: 0 };
	}
	const isHidden = (id: string) => layout.focusedId !== null && layout.focusedId !== id;

	// ---- column / row resize seams (derived from rects + the column tree) ----
	interface Seam {
		kind: 'col' | 'row';
		ci: number;
		ri: number;
		rect: Rect;
	}
	const seams = $derived.by((): Seam[] => {
		const out: Seam[] = [];
		if (layout.focusedId || rects.size === 0) return out;
		layout.columns.forEach((col, ci) => {
			for (let ri = 0; ri < col.length - 1; ri++) {
				const r = rects.get(col[ri]);
				if (r) out.push({ kind: 'row', ci, ri, rect: { left: r.left, top: r.top + r.height, width: r.width, height: SEAM } });
			}
			if (ci < layout.columns.length - 1) {
				const r0 = rects.get(col[0]);
				if (r0) out.push({ kind: 'col', ci, ri: 0, rect: { left: r0.left + r0.width, top: 0, width: SEAM, height: H } });
			}
		});
		return out;
	});

	// ---- drag a tile by its grab handle → re-tile (i3-style directional split) ----
	let ghost = $state<{ x: number; y: number; label: string } | null>(null);
	let drop = $state<{ id: string; side: DropSide } | null>(null);

	function beginDrag(id: string, e: PointerEvent) {
		if (e.button !== 0) return;
		const startX = e.clientX;
		const startY = e.clientY;
		const label = dragLabel(id);
		let active = false;
		const move = (ev: PointerEvent) => {
			if (!active) {
				if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < 5) return;
				active = true;
				layout.startDrag(id);
				document.body.style.userSelect = 'none';
			}
			ghost = { x: ev.clientX, y: ev.clientY, label };
			drop = hitTest(ev.clientX, ev.clientY, id);
		};
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			window.removeEventListener('pointercancel', up);
			document.body.style.userSelect = '';
			if (active) {
				if (drop) layout.dropRelative(id, drop.id, drop.side);
				else layout.endDrag();
			}
			ghost = null;
			drop = null;
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}

	function hitTest(x: number, y: number, draggedId: string): { id: string; side: DropSide } | null {
		if (!host) return null;
		for (const el of host.querySelectorAll<HTMLElement>('[data-tile-id]')) {
			const tid = el.dataset.tileId!;
			if (tid === draggedId) continue;
			const r = el.getBoundingClientRect();
			if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
			const rx = (x - r.left) / r.width - 0.5;
			const ry = (y - r.top) / r.height - 0.5;
			const side: DropSide =
				Math.abs(rx) > Math.abs(ry) ? (rx < 0 ? 'left' : 'right') : ry < 0 ? 'top' : 'bottom';
			return { id: tid, side };
		}
		return null;
	}

	// ---- resize (flex weights become px during a drag; ratios preserved) ----
	function beginColResize(ci: number, e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const widths = layout.columns.map((col) => rects.get(col[0])?.width ?? 0);
		layout.setColSizes([...widths]);
		const startX = e.clientX;
		const a = widths[ci];
		const b = widths[ci + 1];
		const move = (ev: PointerEvent) => {
			const dx = Math.max(-(a - minColPx), Math.min(b - minColPx, ev.clientX - startX));
			const next = [...widths];
			next[ci] = a + dx;
			next[ci + 1] = b - dx;
			layout.setColSizes(next);
		};
		endResize(move);
	}

	function beginRowResize(ci: number, ri: number, e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const heights = layout.columns[ci].map((id) => rects.get(id)?.height ?? 0);
		layout.setRowSizes(ci, [...heights]);
		const startY = e.clientY;
		const a = heights[ri];
		const b = heights[ri + 1];
		const move = (ev: PointerEvent) => {
			const dy = Math.max(-(a - minRowPx), Math.min(b - minRowPx, ev.clientY - startY));
			const next = [...heights];
			next[ri] = a + dy;
			next[ri + 1] = b - dy;
			layout.setRowSizes(ci, next);
		};
		endResize(move);
	}

	function endResize(move: (ev: PointerEvent) => void) {
		document.body.style.userSelect = 'none';
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			document.body.style.userSelect = '';
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
	}

	const sideClass: Record<DropSide, string> = {
		left: 'left-0 top-0 bottom-0 w-1/2',
		right: 'right-0 top-0 bottom-0 w-1/2',
		top: 'left-0 right-0 top-0 h-1/2',
		bottom: 'left-0 right-0 bottom-0 h-1/2'
	};
</script>

<div bind:this={host} class="relative h-full w-full overflow-hidden bg-app">
	{#if tiles.length === 0}
		{#if empty}{@render empty()}{/if}
	{:else}
		{#each tiles as id (id)}
			{@const r = rectFor(id)}
			<div
				data-tile-id={id}
				class="absolute overflow-hidden"
				class:transition-[transform,width,height]={!layout.draggingId}
				class:duration-150={!layout.draggingId}
				style:transform="translate({r.left}px, {r.top}px)"
				style:width="{r.width}px"
				style:height="{r.height}px"
				style:visibility={isHidden(id) ? 'hidden' : 'visible'}
				style:pointer-events={isHidden(id) ? 'none' : 'auto'}
				style:z-index={layout.focusedId === id ? 10 : 1}
			>
				{@render tile(id, (e) => beginDrag(id, e))}
				{#if drop && drop.id === id}
					<div
						class="pointer-events-none absolute z-30 {sideClass[drop.side]}"
						style:background="var(--accent-soft)"
						style:outline="2px solid var(--accent)"
						style:outline-offset="-2px"
					></div>
				{/if}
			</div>
		{/each}

		<!-- resize seams (above tiles) -->
		{#each seams as s (s.kind + s.ci + '-' + s.ri)}
			<div
				class="absolute z-20 {s.kind === 'col' ? 'cursor-ew-resize' : 'cursor-ns-resize'}"
				style:left="{s.rect.left}px"
				style:top="{s.rect.top}px"
				style:width="{s.rect.width}px"
				style:height="{s.rect.height}px"
				role="separator"
				aria-orientation={s.kind === 'col' ? 'vertical' : 'horizontal'}
				tabindex="-1"
				onpointerdown={(e) =>
					s.kind === 'col' ? beginColResize(s.ci, e) : beginRowResize(s.ci, s.ri, e)}
			>
				<div
					class="absolute bg-hair {s.kind === 'col'
						? 'inset-y-0 left-1/2 w-px -translate-x-1/2'
						: 'inset-x-0 top-1/2 h-px -translate-y-1/2'}"
				></div>
				<div
					class="absolute {s.kind === 'col' ? 'inset-y-0 -inset-x-[3px]' : 'inset-x-0 -inset-y-[3px]'}"
				></div>
			</div>
		{/each}

		{#if layout.draggingId && ghost}
			<div
				class="pointer-events-none fixed z-[100] flex -translate-x-1/2 -translate-y-[150%] items-center gap-1.5 rounded-[8px] border border-hair-strong bg-raised px-2.5 py-1 text-ui text-ink-1 shadow-drag"
				style:left="{ghost.x}px"
				style:top="{ghost.y}px"
			>
				{ghost.label}
			</div>
		{/if}
	{/if}
</div>
```

- [ ] **Step 2: Implement `sessions-layout.svelte.ts` (replaces watchset)**

Create `frontend/src/lib/shell/sessions-layout.svelte.ts`:
```ts
// The Sessions watch-set, now built on the generic TileLayout. Owns the
// session-specific semantics the windowing core deliberately omits: a tile cap,
// the user-dismissed set, and reconciliation against live sessions. In Phase 2
// this instance becomes the Sessions space's backing model.

import { TileLayout } from './tiling.svelte';
import { reconcileColumns } from './tiling-core';

const MAX_TILES = 6;

class SessionsLayout {
	layout = new TileLayout();
	/** sessions the user explicitly evicted — not auto-refilled until promoted */
	#dismissed = new Set<string>();

	get watching(): string[] {
		return this.layout.tiles;
	}
	isWatching(id: string): boolean {
		return this.layout.has(id);
	}

	/** Bench → grid: add as a new column on the right (cap-evicting the oldest). */
	promote(id: string): void {
		this.#dismissed.delete(id);
		if (this.layout.has(id)) {
			this.layout.setActive(id);
			return;
		}
		if (this.layout.tileCount >= MAX_TILES) {
			const oldest = this.layout.tiles[0];
			if (oldest) this.layout.remove(oldest);
		}
		this.layout.add(id);
	}

	/** Grid → bench (the × button). */
	evict(id: string): void {
		this.#dismissed.add(id);
		this.layout.remove(id);
	}

	reconcile(candidates: string[]): void {
		for (const id of [...this.#dismissed]) {
			if (!candidates.includes(id)) this.#dismissed.delete(id);
		}
		const next = reconcileColumns(this.layout.columns, candidates, this.#dismissed, MAX_TILES);
		if (JSON.stringify(next) !== JSON.stringify(this.layout.columns)) this.layout.setColumns(next);

		const flat = next.flat();
		if (this.layout.focusedId && !candidates.includes(this.layout.focusedId))
			this.layout.focusedId = null;
		if (!this.layout.activeId || !flat.includes(this.layout.activeId))
			this.layout.activeId = flat[0] ?? null;
	}

	focus(id: string): void {
		if (!this.layout.has(id)) this.promote(id);
		this.layout.focus(id);
	}
	restore(): void {
		this.layout.restore();
	}
	setActive(id: string): void {
		this.layout.setActive(id);
	}
}

export const sessionsLayout = new SessionsLayout();
```

- [ ] **Step 3: Point `SessionPane.svelte` at `sessionsLayout`**

In `frontend/src/lib/components/sessions/SessionPane.svelte`:

Replace the import line:
```svelte
	import { watchSet } from '$lib/shell/watchset.svelte';
```
with:
```svelte
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
```

Replace the three derived lines:
```svelte
	const active = $derived(watchSet.activeId === session.id);
	const focusedMode = $derived(watchSet.focusedId === session.id);
	const dragging = $derived(watchSet.draggingId === session.id);
```
with:
```svelte
	const active = $derived(sessionsLayout.layout.activeId === session.id);
	const focusedMode = $derived(sessionsLayout.layout.focusedId === session.id);
	const dragging = $derived(sessionsLayout.layout.draggingId === session.id);
```

Replace `onpointerdown={() => watchSet.setActive(session.id)}` with `onpointerdown={() => sessionsLayout.setActive(session.id)}`.

Replace in `remove()` the line `watchSet.evict(session.id);` with `sessionsLayout.evict(session.id);`.

Replace `toggleFocus`:
```svelte
	function toggleFocus() {
		if (focusedMode) watchSet.restore();
		else watchSet.focus(session.id);
	}
```
with:
```svelte
	function toggleFocus() {
		if (focusedMode) sessionsLayout.restore();
		else sessionsLayout.focus(session.id);
	}
```

Replace the close button handler `onclick={() => watchSet.evict(session.id)}` with `onclick={() => sessionsLayout.evict(session.id)}`.

- [ ] **Step 4: Point `SessionBench.svelte` at `sessionsLayout`**

In `frontend/src/lib/components/sessions/SessionBench.svelte`:

Replace the import `import { watchSet } from '$lib/shell/watchset.svelte';` with `import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';`.

Replace `watching: watchSet.isWatching(s.id),` with `watching: sessionsLayout.isWatching(s.id),`.

Replace in the `groups` derived `const watching = watchSet.watching` with `const watching = sessionsLayout.watching`.

Replace the bench row handler `onclick={() => watchSet.promote(row.session.id)}` with `onclick={() => sessionsLayout.promote(row.session.id)}`.

- [ ] **Step 5: Render Sessions through `TileGrid` in `+page.svelte`**

Replace `frontend/src/routes/+page.svelte` with:
```svelte
<script lang="ts">
	import TileGrid from '$lib/components/shell/TileGrid.svelte';
	import SessionPane from '$lib/components/sessions/SessionPane.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { shell } from '$lib/shell/shell.svelte';

	const byId = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));

	// Candidate order for auto-filling empty grid slots: attention → running → idle.
	const candidates = $derived.by(() => {
		const rank = (st: { attention: boolean; kind: string }) =>
			st.attention ? 0 : st.kind === 'running' ? 1 : 2;
		return [...sessionsStore.sessions]
			.map((s) => ({ s, st: liveState(s) }))
			.sort((a, b) => rank(a.st) - rank(b.st))
			.map((x) => x.s.id);
	});

	$effect(() => {
		sessionsLayout.reconcile(candidates);
	});

	function onKeydown(e: KeyboardEvent) {
		const el = e.target as HTMLElement | null;
		if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
		if (shell.spacesOpen) return;
		if (e.key === 'Escape') {
			sessionsLayout.restore();
			return;
		}
		const num = Number(e.key);
		if (num >= 1 && num <= 9) {
			const id = sessionsLayout.watching[num - 1];
			if (id) sessionsLayout.setActive(id);
		}
	}

	const label = (id: string) =>
		byId.get(id)?.name || byId.get(id)?.harness_id || 'session';
</script>

<svelte:window onkeydown={onKeydown} />

<TileGrid layout={sessionsLayout.layout} dragLabel={label}>
	{#snippet tile(id, grab)}
		{@const s = byId.get(id)}
		{#if s}
			<SessionPane session={s} {grab} />
		{/if}
	{/snippet}
	{#snippet empty()}
		<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
			<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3">
				<Icon name="sessions" size={22} />
			</div>
			{#if sessionsStore.sessions.length === 0}
				<p class="text-title text-ink-2">No sessions running.</p>
				<p class="max-w-[260px] text-ui text-ink-3">
					Use <span class="text-ink-2">New session</span> in the toolbar to launch an agent, or
					<kbd class="rounded border border-hair bg-inset px-1 font-mono text-meta">⌘K</kbd> to jump to another view.
				</p>
			{:else}
				<p class="text-title text-ink-2">No tiles in the grid.</p>
				<p class="max-w-[260px] text-ui text-ink-3">Promote a session from the bench on the left to watch it here.</p>
			{/if}
		</div>
	{/snippet}
</TileGrid>
```

- [ ] **Step 6: Delete the superseded session-only tiling**

```bash
cd /Users/daniel/Development/legend
git rm frontend/src/lib/components/sessions/WatchSetGrid.svelte frontend/src/lib/shell/watchset.svelte.ts
```

- [ ] **Step 7: Verify type-check, tests, and build**

Run:
```bash
cd frontend && bun run check && bun run test && bun run build
```
Expected: check 0/0; tests pass; build succeeds. If `bun run check` reports any remaining `watchset` import, fix the offending file (grep `watchset` and `watchSet` across `src/`).

- [ ] **Step 8: Manual verification (dev server)**

With `just dev` running, open `:5173`:
- Sessions auto-tile from the bench exactly as before; drag a session's header to split left/right/top/bottom; **the terminal does NOT repaint or rejoin on cross-column drag** (this is the whole point of the flat layer).
- Resize seams drag horizontally/vertically; eye zooms one tile and Esc/eye restores; × evicts; keys 1–9 set active.

- [ ] **Step 9: Commit**

```bash
cd /Users/daniel/Development/legend
git add -A frontend/src
git commit -m "feat(tiling): flat-positioned TileGrid; migrate Sessions onto the windowing core"
```

---

## Task 3: `workspaceStore` (minimal) + `filesStore`

**Files:**
- Create: `frontend/src/lib/stores/files.svelte.ts`
- Create: `frontend/src/lib/shell/workspace.svelte.ts`

**Interfaces:**
- Consumes: `TileLayout` (Task 1), `sessionsLayout` (Task 2), `readFile`/`writeFile`/`deleteFile`/`listTree`/`buildTree` (`$lib/library`).
- Produces:
  - `filesStore` with `buffers` (`$state` record), `has(path)`, `buffer(path)`, `dirty(path): boolean`, `openPaths(): string[]`, `load(path): Promise<void>`, `setContent(path, v)`, `save(path): Promise<void>`, `release(path)`.
  - `workspaceStore` with `spaces: Space[]`, `activeId`, `active: Space`, `switchSpace(id)`, and Library-space tile ops: `openFile(path)`, `setActiveFile(path)`, `splitActiveFile()`, `closeTile(id)`, `tilePath(id): string | null`, `activePath: string | null`. `Space = { id; name; kind: 'sessions'|'library'; layout: TileLayout }`. The `sessions` space's `layout` is `sessionsLayout.layout`.

- [ ] **Step 1: Implement `filesStore`**

Create `frontend/src/lib/stores/files.svelte.ts`:
```ts
import { readFile, writeFile } from '$lib/library';

interface Buffer {
	content: string;
	savedContent: string;
}

/**
 * Open file buffers, keyed by library path and shared across every tile showing
 * that path — so two tiles on one file stay in sync, with one Save and one dirty
 * state. Svelte 5 deeply proxies $state objects, so nested mutation is reactive.
 */
class FilesStore {
	buffers = $state<Record<string, Buffer>>({});
	error = $state('');

	has(path: string): boolean {
		return path in this.buffers;
	}
	buffer(path: string): Buffer | undefined {
		return this.buffers[path];
	}
	dirty(path: string): boolean {
		const b = this.buffers[path];
		return !!b && b.content !== b.savedContent;
	}
	openPaths(): string[] {
		return Object.keys(this.buffers);
	}

	async load(path: string): Promise<void> {
		if (this.buffers[path]) return;
		this.error = '';
		try {
			const content = await readFile(path);
			this.buffers[path] = { content, savedContent: content };
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	setContent(path: string, content: string): void {
		const b = this.buffers[path];
		if (b) b.content = content;
	}

	async save(path: string): Promise<void> {
		const b = this.buffers[path];
		if (!b) return;
		this.error = '';
		try {
			await writeFile(path, b.content);
			b.savedContent = b.content;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	release(path: string): void {
		delete this.buffers[path];
	}
}

export const filesStore = new FilesStore();
```

- [ ] **Step 2: Implement `workspaceStore` (minimal, Phase 1)**

Create `frontend/src/lib/shell/workspace.svelte.ts`:
```ts
// The workspace: a set of Spaces, each a named tiling layout. Phase 1 ships the
// two seeded defaults (Sessions, Library) with known per-space content; Phase 2
// generalizes tile content via the surface registry and adds the launcher,
// custom spaces, and persistence.

import { TileLayout } from './tiling.svelte';
import { sessionsLayout } from './sessions-layout.svelte';
import { filesStore } from '$lib/stores/files.svelte';

export interface Space {
	id: string;
	name: string;
	kind: 'sessions' | 'library';
	layout: TileLayout;
}

class WorkspaceStore {
	spaces = $state<Space[]>([
		{ id: 'sessions', name: 'Sessions', kind: 'sessions', layout: sessionsLayout.layout },
		{ id: 'library', name: 'Library', kind: 'library', layout: new TileLayout() }
	]);
	activeId = $state('sessions');

	/** Library tile id → library path. A tile is a "pane" that shows one file. */
	#paths = $state<Record<string, string>>({});
	#seq = 0;

	get active(): Space {
		return this.spaces.find((s) => s.id === this.activeId) ?? this.spaces[0];
	}
	get library(): Space {
		return this.spaces.find((s) => s.id === 'library')!;
	}

	switchSpace(id: string): void {
		if (this.spaces.some((s) => s.id === id)) this.activeId = id;
	}

	// ---- Library space tile ops -------------------------------------------
	tilePath(id: string): string | null {
		return this.#paths[id] ?? null;
	}
	get activePath(): string | null {
		const a = this.library.layout.activeId;
		return a ? this.tilePath(a) : null;
	}

	/** Open a file: focus an existing tile for it, else add a new tile. */
	openFile(path: string): void {
		const lib = this.library;
		const existing = lib.layout.tiles.find((id) => this.#paths[id] === path);
		if (existing) {
			lib.layout.setActive(existing);
			return;
		}
		const active = lib.layout.activeId;
		if (active && this.#paths[active] === undefined) {
			// active tile has no file yet — fill it
			this.#paths[active] = path;
		} else if (!active || lib.layout.tileCount === 0) {
			const id = this.#mint();
			this.#paths[id] = path;
			lib.layout.add(id);
		} else {
			// re-point the active tile
			this.setActiveFile(path);
		}
		void filesStore.load(path);
	}

	/** Re-point the active Library tile at `path`. */
	setActiveFile(path: string): void {
		const lib = this.library;
		let id = lib.layout.activeId;
		if (!id) {
			id = this.#mint();
			lib.layout.add(id);
		}
		this.#paths[id] = path;
		void filesStore.load(path);
	}

	/** Duplicate the active tile's file into a new tile beside it. */
	splitActiveFile(): void {
		const lib = this.library;
		const active = lib.layout.activeId;
		const path = active ? this.#paths[active] : undefined;
		const id = this.#mint();
		if (path) this.#paths[id] = path;
		lib.layout.add(id);
	}

	closeTile(id: string): void {
		const lib = this.library;
		const path = this.#paths[id];
		delete this.#paths[id];
		lib.layout.remove(id);
		// drop the buffer when no remaining tile references the path
		if (path && !lib.layout.tiles.some((t) => this.#paths[t] === path)) filesStore.release(path);
	}

	#mint(): string {
		return `tile-${++this.#seq}`;
	}
}

export const workspaceStore = new WorkspaceStore();
```

- [ ] **Step 3: Verify type-check and build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0/0; build succeeds. (Stores are unused until Task 4–5; this verifies they compile.)

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/stores/files.svelte.ts frontend/src/lib/shell/workspace.svelte.ts
git commit -m "feat(tiling): filesStore (path-keyed buffers) + minimal workspaceStore"
```

---

## Task 4: `FileSurface` + Library rail + Details side

**Files:**
- Create: `frontend/src/lib/components/library/FileSurface.svelte`
- Create: `frontend/src/lib/components/library/LibraryRail.svelte`
- Create: `frontend/src/lib/components/library/LibrarySide.svelte`

**Interfaces:**
- Consumes: `workspaceStore` (Task 3), `filesStore` (Task 3), `libraryStore` (`$lib/stores/library.svelte` — reused for tree + entries), `LibraryTree`, `SidePane`/`SidePaneSection`/`SidePaneField`, `IconButton`, `Popover`, `ConfirmButton`, `Icon`, `Button`.
- Produces: `FileSurface` props `{ tileId: string; grab?: (e: PointerEvent) => void }`; `LibraryRail` and `LibrarySide` are prop-less (read the stores).

**Note on unsaved edits:** because `filesStore` buffers are keyed by **path** (not by tile), re-pointing a tile away from a dirty file does **not** lose edits — the buffer stays in `filesStore` and the tree keeps its dirty dot. So no switch-time guard is needed in Phase 1 (a real improvement over today's `#pendingOpen` dance). The only loss point is closing the last tile referencing a dirty path; Phase 1 accepts that (flagged), and Phase 2 adds an in-UI two-step confirm on closing a dirty-and-only tile. Do **not** add `window.confirm`.

- [ ] **Step 1: Implement `FileSurface.svelte`**

Create `frontend/src/lib/components/library/FileSurface.svelte`:
```svelte
<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import { Button } from '$lib/components/ui/button';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { filesStore } from '$lib/stores/files.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { deleteFile } from '$lib/library';

	let { tileId, grab }: { tileId: string; grab?: (e: PointerEvent) => void } = $props();

	const layout = workspaceStore.library.layout;
	const path = $derived(workspaceStore.tilePath(tileId));
	const active = $derived(layout.activeId === tileId);
	const focusedMode = $derived(layout.focusedId === tileId);
	const dragging = $derived(layout.draggingId === tileId);
	const buf = $derived(path ? filesStore.buffer(path) : undefined);
	const dirty = $derived(path ? filesStore.dirty(path) : false);
	const crumbs = $derived(path ? path.split('/') : []);

	let menuOpen = $state(false);

	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}

	async function confirmDelete() {
		menuOpen = false;
		if (!path) return;
		try {
			await deleteFile(path);
			filesStore.release(path);
			workspaceStore.closeTile(tileId);
			await libraryStore.refresh();
		} catch (e) {
			libraryStore.error = e instanceof Error ? e.message : 'failed to delete';
		}
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => layout.setActive(tileId)}
>
	<!-- header -->
	<div
		class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-2.5"
		style:background={active
			? 'color-mix(in oklab, var(--accent) 7%, var(--bg-shell))'
			: 'var(--bg-shell)'}
	>
		<div
			class="flex min-w-0 flex-1 items-center gap-1 {dragging ? 'cursor-grabbing' : 'cursor-grab'}"
			onpointerdown={(e) => grab?.(e)}
			role="button"
			tabindex="-1"
			title="Drag to re-tile"
		>
			{#if path}
				<span class="shrink-0 text-meta text-ink-3">Library</span>
				{#each crumbs as c, i (i)}
					<Icon name="chevron-right" size={11} class="shrink-0 text-ink-3" />
					<span class="truncate text-ui {i === crumbs.length - 1 ? 'font-semibold text-ink-1' : 'text-ink-3'}">{c}</span>
				{/each}
			{:else}
				<span class="text-ui text-ink-3">Select a file</span>
			{/if}
		</div>

		{#if dirty}<span class="shrink-0 text-meta text-warn">Unsaved</span>{/if}

		<Button size="sm" class="h-7 px-2.5 text-meta" onclick={() => path && filesStore.save(path)} disabled={!dirty}>Save</Button>
		<IconButton icon="columns" size={14} box={20} title="Split right" onclick={() => workspaceStore.splitActiveFile()} />
		<IconButton icon="eye" size={14} box={20} title={focusedMode ? 'Restore grid' : 'Focus pane'} active={focusedMode} tone="accent" onclick={toggleFocus} />
		<div class="relative shrink-0">
			<IconButton icon="more" size={14} box={20} title="More actions" active={menuOpen} onclick={() => (menuOpen = !menuOpen)} />
			<Popover bind:open={menuOpen} class="right-0 top-[26px] w-[160px]">
				<ConfirmButton idleLabel="Delete file" confirmLabel="Confirm delete" onconfirm={confirmDelete} disabled={!path} />
			</Popover>
		</div>
		<IconButton icon="close" size={14} box={20} title="Close pane" onclick={() => workspaceStore.closeTile(tileId)} />
	</div>

	<!-- body -->
	<div class="relative min-h-0 flex-1 overflow-hidden">
		{#if path && buf}
			<textarea
				value={buf.content}
				oninput={(e) => filesStore.setContent(path, e.currentTarget.value)}
				onkeydown={(e) => {
					if ((e.metaKey || e.ctrlKey) && e.key === 's') {
						e.preventDefault();
						void filesStore.save(path);
					}
				}}
				class="h-full w-full resize-none bg-app p-3.5 font-mono text-body leading-relaxed text-ink-1 outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex h-full items-center justify-center">
				<p class="text-body text-ink-3">Select a file from the tree, or create one.</p>
			</div>
		{/if}
	</div>
</div>
```

If `IconButton`'s `icon="columns"` is not an available `IconName` (check `frontend/src/lib/components/shell/Icon.svelte`), use `icon="panel-right"` (already added in the Library workbench work) instead. Pick whichever exists; do not invent a new glyph in this task.

- [ ] **Step 2: Implement `LibraryRail.svelte`**

Create `frontend/src/lib/components/library/LibraryRail.svelte`:
```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { filesStore } from '$lib/stores/files.svelte';
	import { filterTree } from '$lib/library';

	let searching = $state(false);
	let query = $state('');
	const filtered = $derived(query.trim() ? filterTree(libraryStore.tree, query) : libraryStore.tree);
	const fileCount = $derived(libraryStore.entries.filter((e) => e.type === 'file').length);

	// The first open dirty path drives the dirty dot; the active tile drives selection.
	const dirtyPath = $derived(filesStore.openPaths().find((p) => filesStore.dirty(p)) ?? null);

	onMount(() => void libraryStore.refresh());
</script>

<div class="flex h-full flex-col">
	<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
		{#if searching}
			<!-- svelte-ignore a11y_autofocus -->
			<input
				autofocus
				bind:value={query}
				onblur={() => { if (!query) searching = false; }}
				placeholder="Filter…"
				class="min-w-0 flex-1 bg-transparent text-ui text-ink-1 placeholder:text-ink-3 focus:outline-none"
			/>
		{:else}
			<span class="text-ui font-semibold text-ink-2">Explorer</span>
			<span class="font-mono text-meta text-ink-3">{fileCount}</span>
			<div class="flex-1"></div>
		{/if}
		<IconButton
			icon={searching ? 'close' : 'search'}
			size={13}
			title="Filter library"
			onclick={() => { searching = !searching; if (!searching) query = ''; }}
		/>
	</div>
	<div class="min-h-0 flex-1 overflow-y-auto py-1.5">
		<LibraryTree
			nodes={filtered}
			selected={workspaceStore.activePath}
			{dirtyPath}
			onselect={(p) => workspaceStore.openFile(p)}
		/>
	</div>
</div>
```

- [ ] **Step 3: Implement `LibrarySide.svelte`**

Create `frontend/src/lib/components/library/LibrarySide.svelte`:
```svelte
<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import { Button } from '$lib/components/ui/button';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { relativeTime, formatBytes } from '$lib/shell/format';

	const path = $derived(workspaceStore.activePath);
	const entry = $derived(path ? (libraryStore.entries.find((e) => e.path === path) ?? null) : null);

	function copyReference() {
		if (path && typeof navigator !== 'undefined') void navigator.clipboard?.writeText(path);
	}
</script>

<SidePane title="Details" icon="file">
	{#if entry}
		<SidePaneSection label="File">
			<div class="flex items-center gap-2.5">
				<span class="grid size-9 shrink-0 place-items-center rounded-[9px] border border-hair bg-inset text-ink-2">
					<Icon name="file" size={18} />
				</span>
				<div class="min-w-0">
					<p class="truncate text-body font-semibold text-ink-1">{entry.path.split('/').at(-1)}</p>
					<p class="text-meta text-ink-3">{entry.type === 'dir' ? 'Folder' : 'Document'} · {formatBytes(entry.size)}</p>
				</div>
			</div>
		</SidePaneSection>
		<SidePaneSection label="Details">
			<SidePaneField label="Modified" value={relativeTime(entry.mtime) || '—'} />
			<SidePaneField label="Path" value={entry.path} />
		</SidePaneSection>
	{:else}
		<p class="text-ui text-ink-3">No file selected.</p>
	{/if}

	{#snippet footer()}
		<Button size="sm" variant="outline" class="h-8 w-full text-meta" disabled={!path} onclick={copyReference}>
			<Icon name="link" size={13} class="mr-1.5" />
			Copy reference
		</Button>
	{/snippet}
</SidePane>
```

- [ ] **Step 4: Verify type-check and build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0/0; build succeeds. Fix any `IconName` mismatch per Step 1's note. Confirm `SidePane`'s prop names (`title`, `icon`, `footer` snippet) match its definition; if `SidePane` requires an `onClose`, omit it (optional) — do not pass page-local state.

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/components/library/FileSurface.svelte frontend/src/lib/components/library/LibraryRail.svelte frontend/src/lib/components/library/LibrarySide.svelte
git commit -m "feat(tiling): FileSurface + Library rail/side (split-on-demand editor)"
```

---

## Task 5: Render the active space in the shell + space switcher — PARITY CHECKPOINT

**Files:**
- Create: `frontend/src/lib/components/shell/SpaceSwitcher.svelte`
- Modify: `frontend/src/lib/components/shell/LegendShell.svelte`
- Modify: `frontend/src/routes/+page.svelte` (Sessions tile content moves into the shell renderer)

**Interfaces:**
- Consumes: `workspaceStore` (Task 3), `TileGrid` (Task 2), `WorkbenchLayout`, `SessionPane`, `FileSurface`, `LibraryRail`, `LibrarySide`, `SessionBench`, `sessionsLayout`, `sessionsStore`.

**Design:** the shell renders the active space generically: `WorkbenchLayout` with the space's rail / `TileGrid` primary / side. For Phase 1 the renderer maps `space.kind` → content (Sessions: `SessionBench` rail + `SessionPane` tiles, no side; Library: `LibraryRail` + `FileSurface` tiles + `LibrarySide`). The Sessions reconcile `$effect` and keyboard handler move from `+page.svelte` into the shell so they run regardless of route. `+page.svelte` becomes empty (the shell owns the body).

- [ ] **Step 1: Implement `SpaceSwitcher.svelte`**

Create `frontend/src/lib/components/shell/SpaceSwitcher.svelte`:
```svelte
<script lang="ts">
	import { workspaceStore } from '$lib/shell/workspace.svelte';
</script>

<div class="flex items-center gap-0.5 rounded-[8px] border border-hair bg-inset p-0.5">
	{#each workspaceStore.spaces as s (s.id)}
		<button
			type="button"
			onclick={() => workspaceStore.switchSpace(s.id)}
			class="rounded-[6px] px-2.5 py-1 text-meta font-medium transition-colors"
			style:background={workspaceStore.activeId === s.id ? 'var(--accent-soft)' : 'transparent'}
			style:color={workspaceStore.activeId === s.id ? 'var(--text-1)' : 'var(--text-3)'}
		>
			{s.name}
		</button>
	{/each}
</div>
```

- [ ] **Step 2: Render the active space in `LegendShell.svelte`**

Replace `frontend/src/lib/components/shell/LegendShell.svelte` with:
```svelte
<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import TopBar from './TopBar.svelte';
	import StatusBar from './StatusBar.svelte';
	import SpacesOverlay from './SpacesOverlay.svelte';
	import SpaceSwitcher from './SpaceSwitcher.svelte';
	import WorkbenchLayout from './WorkbenchLayout.svelte';
	import TileGrid from './TileGrid.svelte';
	import Icon from './Icon.svelte';
	import SessionBench from '$lib/components/sessions/SessionBench.svelte';
	import SessionPane from '$lib/components/sessions/SessionPane.svelte';
	import LibraryRail from '$lib/components/library/LibraryRail.svelte';
	import LibrarySide from '$lib/components/library/LibrarySide.svelte';
	import FileSurface from '$lib/components/library/FileSurface.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { sectionForPath, viewById } from '$lib/shell/views';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { liveState } from '$lib/shell/sessionState';

	let { children }: { children: Snippet } = $props();

	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

	const section = $derived(sectionForPath(page.url.pathname));
	const view = $derived(viewById(section));
	const subText = $derived(view?.sub?.() ?? '');
	const chipCount = $derived(view?.count?.());

	const space = $derived(workspaceStore.active);
	const sideOpenKey = $derived(`legend:space:${space.id}:side`);

	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});

	// Sessions auto-tile: keep the watch-set consistent with live sessions.
	const sessionById = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));
	const candidates = $derived.by(() => {
		const rank = (st: { attention: boolean; kind: string }) =>
			st.attention ? 0 : st.kind === 'running' ? 1 : 2;
		return [...sessionsStore.sessions]
			.map((s) => ({ s, st: liveState(s) }))
			.sort((a, b) => rank(a.st) - rank(b.st))
			.map((x) => x.s.id);
	});
	$effect(() => {
		sessionsLayout.reconcile(candidates);
	});
	const sessionLabel = (id: string) =>
		sessionById.get(id)?.name || sessionById.get(id)?.harness_id || 'session';

	function onKeydown(e: KeyboardEvent) {
		if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
			e.preventDefault();
			shell.toggleSpaces();
			return;
		}
		const el = e.target as HTMLElement | null;
		if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
		if (shell.spacesOpen || space.kind !== 'sessions') return;
		if (e.key === 'Escape') {
			sessionsLayout.restore();
			return;
		}
		const num = Number(e.key);
		if (num >= 1 && num <= 9) {
			const id = sessionsLayout.watching[num - 1];
			if (id) sessionsLayout.setActive(id);
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

<div class="relative flex h-dvh w-full flex-col overflow-hidden bg-shell">
	<TopBar {section} sub={subText} count={chipCount} {isTauri} toolbar={view?.toolbar}>
		{#snippet center()}<SpaceSwitcher />{/snippet}
	</TopBar>

	<div class="flex min-h-0 flex-1">
		{#if space.kind === 'sessions'}
			<WorkbenchLayout storageKey={sideOpenKey} sideOpen={false}>
				{#snippet rail()}<SessionBench />{/snippet}
				{#snippet primary()}
					<TileGrid layout={space.layout} dragLabel={sessionLabel}>
						{#snippet tile(id, grab)}
							{@const s = sessionById.get(id)}
							{#if s}<SessionPane session={s} {grab} />{/if}
						{/snippet}
						{#snippet empty()}
							<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
								<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="sessions" size={22} /></div>
								<p class="text-title text-ink-2">{sessionsStore.sessions.length === 0 ? 'No sessions running.' : 'No tiles in the grid.'}</p>
								<p class="max-w-[260px] text-ui text-ink-3">{sessionsStore.sessions.length === 0 ? 'Use New session in the toolbar to launch an agent.' : 'Promote a session from the bench on the left to watch it here.'}</p>
							</div>
						{/snippet}
					</TileGrid>
				{/snippet}
				{#snippet side()}{/snippet}
			</WorkbenchLayout>
		{:else}
			<WorkbenchLayout storageKey={sideOpenKey}>
				{#snippet rail()}<LibraryRail />{/snippet}
				{#snippet primary()}
					<TileGrid layout={space.layout} dragLabel={(id) => workspaceStore.tilePath(id)?.split('/').at(-1) ?? 'file'}>
						{#snippet tile(id, grab)}<FileSurface tileId={id} {grab} />{/snippet}
						{#snippet empty()}
							<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
								<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="folder" size={22} /></div>
								<p class="text-title text-ink-2">No file open.</p>
								<p class="max-w-[260px] text-ui text-ink-3">Pick a file from the Explorer on the left to open it here.</p>
							</div>
						{/snippet}
					</TileGrid>
				{/snippet}
				{#snippet side()}<LibrarySide />{/snippet}
			</WorkbenchLayout>
		{/if}
	</div>

	<StatusBar />

	{#if shell.spacesOpen}
		<SpacesOverlay />
	{/if}
</div>
```

- [ ] **Step 3: Add a `center` snippet slot to `TopBar.svelte`**

Read `frontend/src/lib/components/shell/TopBar.svelte`. Add an optional `center?: Snippet` prop and render `{#if center}{@render center()}{/if}` in the bar's center region (between the section chip and the toolbar). If TopBar already has a natural center area, place it there; otherwise add a `flex-1` spacer wrapper so the switcher sits centered. Keep all existing props (`section`, `sub`, `count`, `isTauri`, `toolbar`) working unchanged.

- [ ] **Step 4: Empty out the Sessions route page**

Replace `frontend/src/routes/+page.svelte` with:
```svelte
<!-- The shell renders the active space; this route just resolves to it. -->
<script lang="ts"></script>
```

- [ ] **Step 5: Verify type-check, tests, build**

Run: `cd frontend && bun run check && bun run test && bun run build`
Expected: check 0/0; tests pass; build succeeds.

- [ ] **Step 6: PARITY CHECKPOINT — manual click-through**

With `just dev` running, at `:5173`:
- **Sessions space** (default): identical to today — bench rail, auto-tile, drag-split with **no terminal repaint**, resize, eye-zoom, ×-evict, keys 1–9. The `New session` toolbar still works.
- **Library space** (switch via the TopBar `SpaceSwitcher`): Explorer tree on the left; clicking a file opens it in the editor tile; edit + ⌘S saves; the **Split** button opens a second pane (A│A); click a tile to make it active, then click another tree file to re-point it (A│B); drag a file pane's header to re-tile; Details side shows the active file's metadata; Copy reference works.
- Confirm no regressions in `TopBar`, `StatusBar`, or the Cmd+K overlay (it still navigates today's routes — that's expected until Phase 2).

**This is the Phase 1 → Phase 2 gate.** Do not start Phase 2 tasks until Sessions + Library are confirmed working here.

- [ ] **Step 7: Commit**

```bash
cd /Users/daniel/Development/legend
git add -A frontend/src
git commit -m "feat(tiling): render active space in the shell + space switcher (parity checkpoint)"
```

---

## Phase 2 (outline — detailed after the Phase 1 checkpoint)

These tasks build the OS workspace on the windowing core. Full per-step plans are written once Phase 1 is verified, so they reflect the real Phase 1 surface.

- **Task 6 — Surface registry.** `src/lib/shell/surfaces.ts`: `SurfaceDef { kind, title, icon, dragLabel?, component, key? }` + `SURFACES` for `session`/`file`/`messages`. `SessionSurface.svelte` + `MessagesSurface.svelte` wrappers. Generalize `workspaceStore` tiles to carry `{ kind, params }` and dedupe via `key`; `openSurface(kind, params)` / `setActiveTileParams` / `splitActive`. The shell's space renderer renders `SURFACES[binding.kind].component` instead of switching on `space.kind`.
- **Task 7 — Modal layer.** `ModalHost.svelte` + `Modal.svelte`; `shell.openModal/closeModal`; move `src/routes/settings/+page.svelte` content into a Settings modal.
- **Task 8 — Launcher.** Evolve `SpacesOverlay` into the launcher: switch/create/rename/save spaces; an **Open** section (New session via `NewSessionDialog`; Open file via a tree-backed picker → `openSurface('file',…)`; Messages → `openSurface('messages',{})`); Settings → modal. Replace `views.ts` with a spaces registry; retire `SpaceSwitcher` in favor of the launcher.
- **Task 9 — Route collapse.** `/library`, `/messages`, `/settings` redirect to the matching space / open the surface or modal; `/sessions/[id]` focuses that session's tile; `/` hosts the shell.
- **Task 10 — Persistence.** `workspace-persistence.ts` (adapter interface + `LocalStoragePersistence`); `workspaceStore` load/save through it; schema `version` + tolerant load (drop unknown kinds, graceful missing-entity tiles); persist per-space side open/width and auto-space dismissals.
- **Task 11 — Docs.** Update `VISION.md` (tiling as the windowing core; surfaces = "UI panels are extension points"; spaces), `ARCHITECTURE.md` (windowing core, registry, workspace/space model, persistence adapter, modal layer, relocated watch-set logic), `DESIGN_SYSTEM.md` (`TileGrid` + space-frame as first-class primitives).

---

## Self-Review (Phase 1)

**Spec coverage (Phase 1 portion):** windowing model (Task 1) ✓; flat-positioned grid with zero remounts (Task 2) ✓; Sessions parity on the primitive (Task 2) ✓; file buffers path-keyed (Task 3) ✓; Library split-on-demand + tree re-pointing + Details side (Tasks 3–4) ✓; active-space rendering via the shell (Task 5) ✓; Vitest for pure logic (Task 1) ✓. Registry/launcher/modal/route-collapse/persistence/docs are Phase 2 (outlined) — matches the spec's migration order and parity checkpoint.

**Placeholder scan:** No TBD/TODO. Component tasks state their verification (check + build + manual) explicitly since there is no component test runner. The two conditional notes (IconName fallback in Task 4; TopBar center placement in Task 5) are concrete decisions with a named fallback, not open-ended "handle it" instructions.

**Type consistency:** `TileLayout` method names (`setColumns`, `add`, `remove`, `dropRelative`, `focus`, `restore`, `setActive`, `rects`, `serialize`/`deserialize`) are used consistently across Tasks 2–5. `sessionsLayout` exposes `.layout` (the `TileLayout`) plus session ops; `SessionPane`/`SessionBench`/shell all read `sessionsLayout.layout.*` for reactive fields and `sessionsLayout.*` for ops — consistent. `workspaceStore` (`active`, `library`, `switchSpace`, `openFile`, `setActiveFile`, `splitActiveFile`, `closeTile`, `tilePath`, `activePath`) is used consistently in Tasks 4–5. `filesStore` (`buffer`, `dirty`, `load`, `setContent`, `save`, `release`, `openPaths`) consistent. `computeRects`/`reconcileColumns` signatures match Task 1 ↔ Task 2 usage.
