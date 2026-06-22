// The workspace: a set of Spaces, each a named tiling layout of surfaces.
// Tiles carry {kind, params} bindings resolved through the surface registry.
// The auto Sessions space is special: its tile ids ARE session ids and its
// bindings are derived; all other spaces store manual bindings.

import { TileLayout } from './tiling.svelte';
import { unplacedRunning, type DropSide } from './tiling-core';
import { sessionsLayout } from './sessions-layout.svelte';
import { filesStore } from '$lib/stores/files.svelte';
import { sessionsStore } from '$lib/stores/sessions.svelte';
import { SURFACES } from './surfaces';
import { WORKSPACE_SCHEMA, type WorkspaceSnapshot } from './workspace-persistence';
import type { IconName } from '$lib/components/shell/Icon.svelte';

export interface Binding {
	kind: string;
	params: Record<string, unknown>;
}

export interface Space {
	id: string;
	name: string;
	icon: IconName;
	auto?: 'sessions';
	layout: TileLayout;
}

class WorkspaceStore {
	spaces = $state<Space[]>([
		{ id: 'workspace', name: 'Workspace', icon: 'sessions', auto: 'sessions', layout: sessionsLayout.layout }
	]);
	activeId = $state('workspace');

	/** manual tile bindings (tileId → {kind,params}); session tiles are derived */
	#bindings = $state<Record<string, Binding>>({});
	#seq = 0;

	get active(): Space {
		return this.spaces.find((s) => s.id === this.activeId) ?? this.spaces[0];
	}
	get #sessionsSpace(): Space {
		return this.spaces.find((s) => s.auto === 'sessions')!;
	}

	switchSpace(id: string): void {
		if (this.spaces.some((s) => s.id === id)) this.activeId = id;
	}

	/** Is this session currently tiled (and therefore on-screen) in the ACTIVE
	 *  space? True for a derived session tile (id === sessionId) or a manual
	 *  session binding. Drives the dock "placed" highlight + the notif filter
	 *  (we only nag about sessions the user can't already see). */
	isSessionVisible(sessionId: string): boolean {
		const sp = this.active;
		return (
			sp.layout.has(sessionId) ||
			sp.layout.tiles.some((t) => {
				const b = this.binding(t);
				return b?.kind === 'session' && b.params.sessionId === sessionId;
			})
		);
	}

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

	/** Resolve a tile id to its surface binding (derived for session tiles).
	 *  A tile recorded in #bindings is a MANUAL tile (file/messages/session) and keeps
	 *  its real kind regardless of which layout it sits in — only a tile NOT in #bindings
	 *  that sits in the auto Sessions layout is a derived session tile (id === sessionId). */
	binding(id: string): Binding | null {
		if (this.#bindings[id]) return this.#bindings[id]; // manual tile — real kind
		if (this.#sessionsSpace.layout.has(id)) return { kind: 'session', params: { sessionId: id } }; // auto session tile
		return null;
	}

	dragLabel(id: string): string {
		const b = this.binding(id);
		if (!b) return 'tile';
		if (b.kind === 'session') {
			// Session tiles bind only {sessionId}; resolve the live name here so the
			// drag ghost shows it instead of the literal "session" fallback.
			const s = sessionsStore.sessions.find((x) => x.id === b.params.sessionId);
			return s?.name || s?.harness_id || 'session';
		}
		const def = SURFACES[b.kind];
		return def?.dragLabel?.(b.params) ?? def?.title(b.params) ?? b.kind;
	}

	// ---- generic surface opening -----------------------------------------
	/** Open a surface into the active space. Session tiles on the auto space are
	 *  promoted (their ids ARE session ids); everything else — files, messages,
	 *  even on the auto space — opens as a manual tile (reconcileSessions only
	 *  prunes/appends SESSION tiles, so mixed surfaces are safe there).
	 *  `placement` (from a dock drag) inserts the new tile relative to a target. */
	openSurface(
		kind: string,
		params: Record<string, unknown>,
		placement?: { targetId: string; side: DropSide }
	): void {
		if (this.active.auto && kind === 'session') {
			sessionsLayout.promote(params.sessionId as string);
			return;
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

	// ---- file tile helpers (the dock's FilesSource opens via openSurface) ----
	tilePath(id: string): string | null {
		const b = this.binding(id);
		return b?.kind === 'file' ? (b.params.path as string) : null;
	}
	/** The active file is the active tile of the ACTIVE space if it's a file. */
	get activePath(): string | null {
		const id = this.active.layout.activeId;
		return id ? this.tilePath(id) : null;
	}

	// ---- custom space management -----------------------------------------
	createSpace(name = 'Workspace'): string {
		const id = `space-${++this.#seq}`;
		this.spaces = [...this.spaces, { id, name, icon: 'grid', layout: new TileLayout() }];
		this.activeId = id;
		return id;
	}
	renameSpace(id: string, name: string): void {
		this.spaces = this.spaces.map((s) => (s.id === id ? { ...s, name } : s));
	}
	deleteSpace(id: string): void {
		const sp = this.spaces.find((s) => s.id === id);
		if (!sp || sp.auto) return; // never delete the default auto space
		for (const t of sp.layout.tiles) delete this.#bindings[t];
		this.spaces = this.spaces.filter((s) => s.id !== id);
		if (this.activeId === id) this.activeId = this.#sessionsSpace.id;
	}

	#mint(): string {
		return `tile-${++this.#seq}`;
	}

	// ---- persistence (snapshot / hydrate) --------------------------------
	/**
	 * Capture the workspace as a serializable snapshot. READS reactive state so a
	 * `$effect` calling this tracks changes and re-saves. EVERY space (including the
	 * auto Sessions space) serializes its real layout + bindings so the workspace
	 * restores exactly on reload; session tiles serialize as `{kind:'session'}`.
	 */
	snapshot(): WorkspaceSnapshot {
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
				icon: space.icon,
				auto: space.auto,
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
					// sessionsLayout.layout so the reconcile keeps working — and
					// restore its saved layout onto it so session tiles persist.
					noteSeq(entry.id, 'space-');
					// The default space is renameable, so restore its saved name.
					if (entry.name) live.name = entry.name;
					live.layout.deserialize(entry.layout);
					// Session tiles are derived from layout membership; restore only the
					// MANUAL (file/messages) bindings so non-session tiles in the default
					// space survive reload instead of becoming binding-less orphan ids.
					for (const b of entry.bindings) {
						noteSeq(b.id, 'tile-');
						if (b.kind !== 'session' && SURFACES[b.kind])
							bindings[b.id] = { kind: b.kind, params: b.params };
					}
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
					icon: entry.icon ?? ((entry.auto === 'sessions' ? 'sessions' : 'grid') as IconName),
					layout
				};
			});

			this.spaces = spaces;
			this.#bindings = bindings;
			this.activeId = spaces.some((s) => s.id === snap.activeId)
				? snap.activeId
				: this.#sessionsSpace.id;
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
