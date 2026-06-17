// The workspace: a set of Spaces, each a named tiling layout of surfaces.
// Tiles carry {kind, params} bindings resolved through the surface registry.
// The auto Sessions space is special: its tile ids ARE session ids and its
// bindings are derived; all other spaces store manual bindings.

import { TileLayout } from './tiling.svelte';
import { sessionsLayout } from './sessions-layout.svelte';
import { filesStore } from '$lib/stores/files.svelte';
import { SURFACES } from './surfaces';
import { WORKSPACE_SCHEMA, type WorkspaceSnapshot } from './workspace-persistence';

export interface Binding {
	kind: string;
	params: Record<string, unknown>;
}

export interface Space {
	id: string;
	name: string;
	auto?: 'sessions';
	rail?: 'library';
	side?: 'library';
	layout: TileLayout;
}

class WorkspaceStore {
	spaces = $state<Space[]>([
		{ id: 'sessions', name: 'Sessions', auto: 'sessions', layout: sessionsLayout.layout },
		{ id: 'library', name: 'Library', rail: 'library', side: 'library', layout: new TileLayout() }
	]);
	activeId = $state('sessions');

	/** manual tile bindings (tileId → {kind,params}); session tiles are derived */
	#bindings = $state<Record<string, Binding>>({});
	#seq = 0;

	get active(): Space {
		return this.spaces.find((s) => s.id === this.activeId) ?? this.spaces[0];
	}
	get library(): Space {
		return this.spaces.find((s) => s.id === 'library')!;
	}
	get #sessionsSpace(): Space {
		return this.spaces.find((s) => s.auto === 'sessions')!;
	}

	switchSpace(id: string): void {
		if (this.spaces.some((s) => s.id === id)) this.activeId = id;
	}

	/** Resolve a tile id to its surface binding (derived for session tiles). */
	binding(id: string): Binding | null {
		if (this.#sessionsSpace.layout.has(id)) return { kind: 'session', params: { sessionId: id } };
		return this.#bindings[id] ?? null;
	}

	dragLabel(id: string): string {
		const b = this.binding(id);
		if (!b) return 'tile';
		const def = SURFACES[b.kind];
		return def?.dragLabel?.(b.params) ?? def?.title(b.params) ?? b.kind;
	}

	// ---- generic surface opening -----------------------------------------
	/** Open a surface into the active space, routing off the auto Sessions space. */
	openSurface(kind: string, params: Record<string, unknown>): void {
		if (this.active.auto) {
			if (kind === 'session') {
				sessionsLayout.promote(params.sessionId as string);
				return;
			}
			this.switchSpace(kind === 'file' ? 'library' : this.#ensureCustom());
		}
		this.#addOrFocus(this.active, kind, params);
		if (kind === 'file') void filesStore.load(params.path as string);
	}

	#addOrFocus(space: Space, kind: string, params: Record<string, unknown>): void {
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
	}

	/** Duplicate the active tile's binding into a new tile beside it. */
	splitActive(): void {
		const space = this.active;
		const active = space.layout.activeId;
		if (!active) return;
		const b = this.binding(active);
		if (!b || b.kind === 'session') {
			// sessions can't be duplicated (one PTY view per tile here); no-op
			return;
		}
		const id = this.#mint();
		this.#bindings[id] = { kind: b.kind, params: { ...b.params } };
		space.layout.add(id);
	}

	/** Re-point the active tile's params (Library tree-click model). */
	setActiveTileParams(params: Record<string, unknown>): void {
		const space = this.active;
		const id = space.layout.activeId;
		if (!id) return;
		const b = this.#bindings[id];
		if (b) this.#bindings[id] = { ...b, params };
	}

	closeTile(id: string): void {
		if (this.#sessionsSpace.layout.has(id)) {
			sessionsLayout.evict(id);
			return;
		}
		const b = this.#bindings[id];
		delete this.#bindings[id];
		for (const s of this.spaces) if (s.layout.has(id)) s.layout.remove(id);
		if (b?.kind === 'file') {
			const path = b.params.path as string;
			const stillOpen = Object.values(this.#bindings).some(
				(x) => x.kind === 'file' && x.params.path === path
			);
			if (!stillOpen) filesStore.release(path);
		}
	}

	// ---- Library file ops (tree-click model from Phase 1, on the Library space)
	tilePath(id: string): string | null {
		const b = this.binding(id);
		return b?.kind === 'file' ? (b.params.path as string) : null;
	}
	get activePath(): string | null {
		const id = this.library.layout.activeId;
		return id ? this.tilePath(id) : null;
	}

	/** Tree-click: re-point the active Library tile, or open the first tile. */
	openFile(path: string): void {
		const lib = this.library;
		this.switchSpace('library');
		const existing = lib.layout.tiles.find((id) => this.#tilePathIn(id) === path);
		if (existing) {
			lib.layout.setActive(existing);
			void filesStore.load(path);
			return;
		}
		const active = lib.layout.activeId;
		if (active && this.#bindings[active]?.kind === 'file') {
			this.#bindings[active] = { kind: 'file', params: { path } };
		} else {
			const id = this.#mint();
			this.#bindings[id] = { kind: 'file', params: { path } };
			lib.layout.add(id);
		}
		void filesStore.load(path);
	}
	#tilePathIn(id: string): string | null {
		const b = this.#bindings[id];
		return b?.kind === 'file' ? (b.params.path as string) : null;
	}
	setActiveFile(path: string): void {
		this.openFile(path);
	}

	// ---- custom space management -----------------------------------------
	createSpace(name = 'Workspace'): string {
		const id = `space-${++this.#seq}`;
		this.spaces = [...this.spaces, { id, name, layout: new TileLayout() }];
		this.activeId = id;
		return id;
	}
	renameSpace(id: string, name: string): void {
		this.spaces = this.spaces.map((s) => (s.id === id ? { ...s, name } : s));
	}
	deleteSpace(id: string): void {
		const sp = this.spaces.find((s) => s.id === id);
		if (!sp || sp.auto || sp.id === 'library') return; // never delete seeded spaces
		for (const t of sp.layout.tiles) delete this.#bindings[t];
		this.spaces = this.spaces.filter((s) => s.id !== id);
		if (this.activeId === id) this.activeId = 'sessions';
	}
	#ensureCustom(): string {
		const custom = this.spaces.find((s) => !s.auto && s.id !== 'library');
		return custom ? custom.id : this.createSpace();
	}

	#mint(): string {
		return `tile-${++this.#seq}`;
	}

	// ---- persistence (snapshot / hydrate) --------------------------------
	/**
	 * Capture the workspace as a serializable snapshot. READS reactive state so a
	 * `$effect` calling this tracks changes and re-saves. The auto Sessions space
	 * is recorded as a marker only (empty layout/bindings) — it repopulates from
	 * live sessions via the reconcile effect.
	 */
	snapshot(): WorkspaceSnapshot {
		const spaces = this.spaces.map((space) => {
			if (space.auto) {
				return {
					id: space.id,
					name: space.name,
					auto: space.auto,
					rail: space.rail,
					side: space.side,
					layout: new TileLayout().serialize(),
					bindings: []
				};
			}
			const bindings = space.layout.tiles
				.map((id) => ({ id, ...this.#bindings[id] }))
				.filter((b) => b.kind);
			return {
				id: space.id,
				name: space.name,
				rail: space.rail,
				side: space.side,
				layout: space.layout.serialize(),
				bindings
			};
		});
		return {
			version: WORKSPACE_SCHEMA,
			activeId: this.activeId,
			dismissed: sessionsLayout.dismissedIds(),
			spaces
		};
	}

	/**
	 * Rebuild the workspace from a snapshot. Tolerant: a null snapshot or ANY
	 * error keeps the seeded defaults. Unknown surface kinds are dropped; missing
	 * files are tolerated (the FileSurface shows its empty/missing state).
	 */
	hydrate(snap: WorkspaceSnapshot | null): void {
		if (!snap) return; // keep seeded defaults
		try {
			let maxSeq = this.#seq;
			const noteSeq = (id: string, prefix: string) => {
				if (id.startsWith(prefix)) {
					const n = Number.parseInt(id.slice(prefix.length), 10);
					if (Number.isFinite(n) && n > maxSeq) maxSeq = n;
				}
			};

			const live = this.#sessionsSpace;
			const bindings: Record<string, Binding> = {};

			const spaces: Space[] = snap.spaces.map((entry) => {
				if (entry.auto === 'sessions') {
					// KEEP the live sessions space — its layout MUST stay
					// sessionsLayout.layout so the reconcile $effect keeps working.
					noteSeq(entry.id, 'space-');
					return live;
				}
				noteSeq(entry.id, 'space-');
				const layout = new TileLayout();
				layout.deserialize(entry.layout);
				for (const b of entry.bindings) {
					noteSeq(b.id, 'tile-');
					if (SURFACES[b.kind]) bindings[b.id] = { kind: b.kind, params: b.params };
				}
				return {
					id: entry.id,
					name: entry.name,
					rail: entry.rail,
					side: entry.side,
					layout
				};
			});

			this.spaces = spaces;
			this.#bindings = bindings;
			this.activeId = spaces.some((s) => s.id === snap.activeId) ? snap.activeId : 'sessions';
			sessionsLayout.restoreDismissed(snap.dismissed ?? []);

			// Collision guard: advance #seq past the largest restored numeric suffix
			// so newly minted tile-/space- ids never collide with restored ones.
			this.#seq = maxSeq;

			// Lazy-load restored file buffers (tolerate missing — errors route to
			// filesStore.error and the FileSurface shows its empty state).
			for (const b of Object.values(bindings)) {
				if (b.kind === 'file' && typeof b.params.path === 'string') {
					void filesStore.load(b.params.path);
				}
			}
		} catch {
			// tolerant: any failure leaves the seeded defaults intact
		}
	}
}

export const workspaceStore = new WorkspaceStore();
