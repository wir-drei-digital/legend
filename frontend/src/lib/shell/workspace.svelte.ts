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
