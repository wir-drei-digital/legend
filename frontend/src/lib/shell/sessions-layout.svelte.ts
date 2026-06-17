// The Sessions watch-set, now built on the generic TileLayout. Owns the
// session-specific semantics the windowing core deliberately omits: a tile cap,
// the user-dismissed set, and reconciliation against live sessions. In Phase 2
// this instance becomes the Sessions space's backing model.

import { SvelteSet } from 'svelte/reactivity';
import { TileLayout } from './tiling.svelte';
import { reconcileColumns } from './tiling-core';

const MAX_TILES = 6;

class SessionsLayout {
	layout = new TileLayout();
	/**
	 * Sessions the user explicitly evicted — not auto-refilled until promoted.
	 * Reactive (SvelteSet) so `dismissedIds()` iterating it registers a dependency
	 * and the workspace save `$effect` re-runs on every add/delete; .add/.delete/
	 * iteration semantics match a plain Set.
	 */
	#dismissed = new SvelteSet<string>();

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

	/** Snapshot the user-dismissed set so the workspace snapshot can persist it. */
	dismissedIds(): string[] {
		return [...this.#dismissed];
	}
	/** Restore the user-dismissed set from a workspace snapshot. */
	restoreDismissed(ids: string[]): void {
		this.#dismissed.clear();
		for (const id of ids) this.#dismissed.add(id);
	}
	setActive(id: string): void {
		this.layout.setActive(id);
	}
}

export const sessionsLayout = new SessionsLayout();
