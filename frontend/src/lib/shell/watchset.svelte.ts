// The watch-set: sessions tiled in the grid right now, arranged as resizable
// columns. `columns` is left→right; each column is a top→bottom stack of tiles.
// It's a mouse-driven tiling window manager (think i3): drag a tile's header
// onto another tile's edge to split in that direction; drag the seams to resize.

const MAX_TILES = 6;

export type DropSide = 'left' | 'right' | 'top' | 'bottom';

class WatchSet {
	/** columns left→right; each is a top→bottom stack of session ids */
	columns = $state<string[][]>([]);
	/** per-column flex-grow (px-derived on resize); empty = all equal */
	colSizes = $state<number[]>([]);
	/** per-column, per-row flex-grow; empty/short = equal */
	rowSizes = $state<number[][]>([]);
	/** eye → expand one tile to the full body; Esc / eye again restores */
	focusedId = $state<string | null>(null);
	/** the accent-highlighted tile (last interacted) */
	activeId = $state<string | null>(null);
	/** the tile currently being dragged (drives the drag overlay) */
	draggingId = $state<string | null>(null);

	/** sessions the user explicitly evicted — not auto-refilled until promoted. */
	#dismissed = new Set<string>();

	get watching(): string[] {
		return this.columns.flat();
	}
	get tileCount(): number {
		return this.columns.reduce((n, c) => n + c.length, 0);
	}

	isWatching(id: string): boolean {
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

	/** Bench → grid: add as a new column on the right. */
	promote(id: string): void {
		this.#dismissed.delete(id);
		if (this.isWatching(id)) {
			this.activeId = id;
			return;
		}
		if (this.tileCount >= MAX_TILES) this.#evictOldest();
		this.#commit([...this.#clone(), [id]]);
		this.activeId = id;
	}

	/** Grid → bench (the × button). */
	evict(id: string): void {
		this.#dismissed.add(id);
		this.#commit(this.#cloneWithout(id));
		if (this.focusedId === id) this.focusedId = null;
		if (this.activeId === id) this.activeId = this.watching.at(-1) ?? null;
	}

	setActive(id: string): void {
		this.activeId = id;
	}

	focus(id: string): void {
		if (!this.isWatching(id)) this.promote(id);
		this.focusedId = id;
		this.activeId = id;
	}
	restore(): void {
		this.focusedId = null;
	}

	// ---- drag & drop tiling -------------------------------------------------

	startDrag(id: string): void {
		this.draggingId = id;
	}
	endDrag(): void {
		this.draggingId = null;
	}

	/**
	 * Drop the dragged tile relative to `targetId`: left/right inserts a new
	 * column beside the target's column; top/bottom splits the target's column,
	 * stacking above/below the target tile. Reference-based so removing the
	 * dragged tile first can't shift the target out from under us.
	 */
	dropRelative(id: string, targetId: string, side: DropSide): void {
		this.draggingId = null;
		if (id === targetId) return;
		const cols = this.#cloneWithout(id);
		const ci = cols.findIndex((c) => c.includes(targetId));
		if (ci < 0) {
			cols.push([id]);
		} else if (side === 'left' || side === 'right') {
			cols.splice(side === 'left' ? ci : ci + 1, 0, [id]);
		} else {
			const col = cols[ci];
			const ri = col.indexOf(targetId);
			col.splice(side === 'top' ? ri : ri + 1, 0, id);
		}
		this.#commit(cols.filter((c) => c.length));
		this.activeId = id;
	}

	// ---- reconciliation with live sessions ---------------------------------

	reconcile(candidates: string[]): void {
		const live = new Set(candidates);
		for (const id of [...this.#dismissed]) if (!live.has(id)) this.#dismissed.delete(id);

		const cols = this.columns.map((c) => c.filter((id) => live.has(id))).filter((c) => c.length);
		const present = new Set(cols.flat());
		let count = present.size;
		for (const id of candidates) {
			if (count >= MAX_TILES) break;
			if (present.has(id) || this.#dismissed.has(id)) continue;
			cols.push([id]);
			present.add(id);
			count++;
		}

		if (JSON.stringify(cols) !== JSON.stringify(this.columns)) this.#commit(cols);

		const flat = cols.flat();
		if (this.focusedId && !live.has(this.focusedId)) this.focusedId = null;
		if (!this.activeId || !flat.includes(this.activeId)) this.activeId = flat[0] ?? null;
	}

	// ---- internals ----------------------------------------------------------

	/** Assign a new column layout and reset sizes to equal (structure changed). */
	#commit(cols: string[][]): void {
		this.columns = cols;
		this.colSizes = [];
		this.rowSizes = [];
	}
	#clone(): string[][] {
		return this.columns.map((c) => [...c]);
	}
	#cloneWithout(id: string): string[][] {
		return this.columns.map((c) => c.filter((x) => x !== id)).filter((c) => c.length);
	}
	#evictOldest(): void {
		const oldest = this.watching[0];
		if (oldest) this.#commit(this.#cloneWithout(oldest));
	}
}

export const watchSet = new WatchSet();
