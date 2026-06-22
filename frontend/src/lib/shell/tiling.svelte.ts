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
		// Defensive: a focused/active id that isn't a real tile (stale or corrupt
		// snapshot) would blank the grid — drop it rather than trust it.
		this.focusedId = snap.focusedId && this.has(snap.focusedId) ? snap.focusedId : null;
		this.activeId = snap.activeId && this.has(snap.activeId) ? snap.activeId : null;
	}
}
