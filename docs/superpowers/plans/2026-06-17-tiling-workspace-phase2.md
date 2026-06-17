# Tiling Workspace — Phase 2 Implementation Plan (OS workspace)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the agentic-OS workspace on the Phase 1 windowing core: a surface registry, mixed-surface custom spaces, an app launcher, a Settings modal, route collapse, and localStorage persistence.

**Architecture:** Tiles become `{kind, params}` bindings resolved through a surface registry (`session`/`file`/`messages` → component). `SessionPane` is decoupled from `sessionsLayout` so a session can render in any space's layout. The launcher (evolved Cmd+K overlay) switches/creates spaces and opens surfaces. Spaces persist through a swappable adapter (localStorage now, SQLite/sync later).

**Tech Stack:** SvelteKit 2 SPA (`ssr=false`), Svelte 5 runes, TypeScript, Tailwind v4 + Legend tokens, shadcn `Dialog`, Bun, Vitest.

**Spec:** `docs/superpowers/specs/2026-06-17-tiling-workspace-design.md`
**Phase 1 (done, branch `feat/tiling-workspace` @ 740da56):** `TileLayout` + `tiling-core` + flat `TileGrid`; `sessionsLayout`; `filesStore`; minimal `workspaceStore`; `FileSurface`/`LibraryRail`/`LibrarySide`; shell renders the active space (Sessions bench-direct, Library via `WorkbenchLayout`) + `SpaceSwitcher`. Parity verified live.

## Global Constraints

- Frontend only (`frontend/`). No backend/Elixir changes.
- Svelte 5 runes only. Design tokens only (`text-ink-1/2/3`, `bg-shell/app/panel/raised/inset`, `border-hair`/`border-hair-strong`, `text-brand/brand-hi`, `bg-[var(--accent-soft)]`, `text-ok/warn/bad`, type scale `text-micro/meta/ui/body/title`, `--h-bar`/`--h-row`); no raw shadcn neutral classes, no ad-hoc hex, no ad-hoc `text-[Npx]`; shadcn semantic classes only under `src/lib/components/ui/`.
- NEVER `window.confirm`/`alert`/`prompt` — in-UI confirmation only. No `window`/`localStorage`/`document` at module top level (guard in `onMount`/handlers/`$effect`).
- `bun run check` 0 errors/0 warnings; `bun run build` succeeds; `bun run test` (Vitest) passes.
- The flat-positioned `TileGrid` invariant from Phase 1 stands: tiles render once, never reparent. Do not regress it.
- Re-verify Sessions + Library live parity after the `SessionPane` decouple (Task 7) before proceeding.

## Locked architecture decisions

1. **Surface registry** (`surfaces.ts`): `SurfaceDef { kind; title(params); icon; dragLabel?(params); key?(params); component }`. `SURFACES: Record<string, SurfaceDef>` for `session`/`file`/`messages`. Every surface component takes the **uniform props** `{ tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void }` and gets everything else from `workspaceStore` (a rendered tile is always in the active space, so `workspaceStore.active.layout` is its layout; `workspaceStore.closeTile(tileId)` does the right thing per space).

2. **Bindings**: `workspaceStore` stores `#bindings: Record<tileId, {kind, params}>` for MANUAL tiles. Session tiles live in the auto Sessions space with `tileId === sessionId`; their binding is DERIVED (`{kind:'session', params:{sessionId:id}}`). Manual tile ids are `tile-N` (no collision with session UUIDs).

3. **Spaces**: `Space { id; name; auto?: 'sessions'; rail?: 'library'; side?: 'library'; layout }`. Seeded: Sessions (`auto:'sessions'`), Library (`rail:'library', side:'library'`). Custom spaces have none (grid-only). `kind` union from Phase 1 is removed.

4. **Auto Sessions space stays sessions-only** (reconcile would clobber foreign tiles). `openSurface` routing: if the active space is auto, `kind:'session'` → `sessionsLayout.promote`; `kind:'file'` → switch to Library; else → switch to (or create) a custom space. Non-auto spaces receive the surface directly.

5. **`SessionPane` decoupled**: takes `{ session, grab, layout, onClose }` and reads `layout` (not `sessionsLayout`) for active/focus/drag/setActive; calls `onClose()` to close. The auto Sessions space passes `layout=sessionsLayout.layout`, `onClose=()=>sessionsLayout.evict(id)`; everywhere else `SessionSurface` passes `layout=workspaceStore.active.layout`, `onClose=()=>workspaceStore.closeTile(tileId)`.

6. **Modal layer = shadcn `Dialog`** (already used by `NewSessionDialog`), not a bespoke `ModalHost`. Settings becomes a `Dialog` driven by `shell.settingsOpen`.

7. **Persistence via adapter**: `WorkspacePersistence` interface, default `LocalStoragePersistence`. Persists spaces (name, layout snapshot, manual bindings), active space, per-space side width/open, auto-space dismissals. Versioned + tolerant load (drop unknown kinds, render missing-entity tiles gracefully, never crash). Sessions are NOT persisted as bindings (auto space repopulates from live data).

---

## File Structure (Phase 2)

**New:**
- `frontend/src/lib/shell/surfaces.ts` — surface registry.
- `frontend/src/lib/components/surfaces/SessionSurface.svelte` — wraps `SessionPane`.
- `frontend/src/lib/components/surfaces/MessagesSurface.svelte` — the messages thread view (extracted from `routes/messages/+page.svelte`).
- `frontend/src/lib/components/shell/SettingsModal.svelte` — settings content in a shadcn `Dialog`.
- `frontend/src/lib/shell/workspace-persistence.ts` — persistence adapter + localStorage impl.

**Modified:**
- `frontend/src/lib/components/sessions/SessionPane.svelte` — decouple from `sessionsLayout` (props).
- `frontend/src/lib/shell/workspace.svelte.ts` — `{kind,params}` bindings, `openSurface`/`splitActive`/`setActiveTileParams`/`closeTile`, custom-space CRUD, persistence wiring.
- `frontend/src/lib/components/library/FileSurface.svelte` — `splitActiveFile()` → `splitActive()` (one call site).
- `frontend/src/lib/components/shell/LegendShell.svelte` — uniform registry-driven tile snippet; render Sessions/Library/custom frames; mount `SettingsModal`.
- `frontend/src/lib/components/shell/SpacesOverlay.svelte` — becomes the launcher.
- `frontend/src/lib/shell/shell.svelte.ts` — add `settingsOpen` + open/close.
- `frontend/src/routes/{library,messages,settings}/+page.svelte` — redirect to space/surface/modal; `frontend/src/routes/sessions/[id]/+page.svelte` — focus the session tile.

**Deleted:**
- `frontend/src/lib/components/shell/SpaceSwitcher.svelte` (launcher supersedes it).
- `frontend/src/lib/shell/views.ts` (replaced by the spaces model) — only after all readers migrate.

---

## Task 6: Surface registry + Session/Messages surfaces

**Files:**
- Create: `frontend/src/lib/shell/surfaces.ts`, `frontend/src/lib/components/surfaces/SessionSurface.svelte`, `frontend/src/lib/components/surfaces/MessagesSurface.svelte`
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte` (decouple — also Task 7's subject; do it here so `SessionSurface` compiles)

**Interfaces:**
- Produces: `SurfaceDef`, `SURFACES` (`session`/`file`/`messages`); surface components with props `{ tileId, params, grab }`.
- `SessionPane` new props: `{ session: Session; grab?: (e)=>void; layout: TileLayout; onClose: () => void }`.

- [ ] **Step 1: Decouple `SessionPane` from `sessionsLayout`**

In `frontend/src/lib/components/sessions/SessionPane.svelte`:

Replace the import `import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';` with `import type { TileLayout } from '$lib/shell/tiling.svelte';`.

Change the props block from:
```svelte
	let { session, grab }: { session: Session; grab?: (e: PointerEvent) => void } = $props();
```
to:
```svelte
	let {
		session,
		grab,
		layout,
		onClose
	}: {
		session: Session;
		grab?: (e: PointerEvent) => void;
		layout: TileLayout;
		onClose: () => void;
	} = $props();
```

Replace every `sessionsLayout.layout.X` and `sessionsLayout.X` with the passed `layout` / handlers:
- `const active = $derived(sessionsLayout.layout.activeId === session.id);` → `const active = $derived(layout.activeId === session.id);`
- `const focusedMode = $derived(sessionsLayout.layout.focusedId === session.id);` → `layout.focusedId`
- `const dragging = $derived(sessionsLayout.layout.draggingId === session.id);` → `layout.draggingId`
- `onpointerdown={() => sessionsLayout.setActive(session.id)}` → `onpointerdown={() => layout.setActive(session.id)}`
- in `remove()`: `sessionsLayout.evict(session.id);` → `onClose();`
- `toggleFocus`: `if (focusedMode) sessionsLayout.restore(); else sessionsLayout.focus(session.id);` → `if (focusedMode) layout.restore(); else layout.focus(session.id);`
- the close button `onclick={() => sessionsLayout.evict(session.id)}` → `onclick={onClose}`

- [ ] **Step 2: Create `SessionSurface.svelte`**

`frontend/src/lib/components/surfaces/SessionSurface.svelte`:
```svelte
<script lang="ts">
	import SessionPane from '$lib/components/sessions/SessionPane.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';

	let { tileId, params, grab }: { tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void } = $props();

	const sessionId = $derived(params.sessionId as string);
	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId) ?? null);
	const layout = $derived(workspaceStore.active.layout);
</script>

{#if session}
	<SessionPane {session} {grab} {layout} onClose={() => workspaceStore.closeTile(tileId)} />
{:else}
	<div class="flex h-full flex-col items-center justify-center gap-2 bg-app px-6 text-center">
		<Icon name="sessions" size={22} class="text-ink-3" />
		<p class="text-ui text-ink-2">Session unavailable</p>
		<p class="text-meta text-ink-3">It may have stopped or been removed.</p>
		<button type="button" class="mt-1 text-meta text-brand-hi" onclick={() => workspaceStore.closeTile(tileId)}>Close tile</button>
	</div>
{/if}
```

- [ ] **Step 3: Create `MessagesSurface.svelte`** (extract the body of `routes/messages/+page.svelte` into a tile surface)

`frontend/src/lib/components/surfaces/MessagesSurface.svelte`: copy the `<script>` logic and markup from `frontend/src/routes/messages/+page.svelte` VERBATIM (the `byId`/`rootOf`/`sessionLabel`/`groups`/`kindBadge` logic and the `<div class="flex h-full flex-col gap-3 p-4">…</div>` template with the thread list + `<MessageComposer />`), with these adjustments: add the surface props line `let { tileId, params, grab }: { tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void } = $props();` (params/tileId unused for now but part of the uniform contract — reference `void params; void tileId; void grab;` if svelte-check flags unused, or omit the destructured names you don't use and keep the type). Keep the existing `$effect` that calls `messagesStore.connect()`/`sessionsStore.connect()`. Wrap the existing root in a full-height container so it fills the tile.

- [ ] **Step 4: Create `surfaces.ts`**

`frontend/src/lib/shell/surfaces.ts`:
```ts
import type { Component } from 'svelte';
import type { IconName } from '$lib/components/shell/Icon.svelte';
import SessionSurface from '$lib/components/surfaces/SessionSurface.svelte';
import FileSurface from '$lib/components/library/FileSurface.svelte';
import MessagesSurface from '$lib/components/surfaces/MessagesSurface.svelte';

export interface SurfaceDef {
	kind: string;
	title: (params: Record<string, unknown>) => string;
	icon: IconName;
	dragLabel?: (params: Record<string, unknown>) => string;
	/** stable identity for dedupe ("focus existing instead of duplicate") */
	key?: (params: Record<string, unknown>) => string;
	component: Component<{ tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void }>;
}

export const SURFACES: Record<string, SurfaceDef> = {
	session: {
		kind: 'session',
		title: (p) => (p.name as string) || 'session',
		icon: 'sessions',
		dragLabel: (p) => (p.name as string) || 'session',
		key: (p) => `session:${p.sessionId}`,
		component: SessionSurface
	},
	file: {
		kind: 'file',
		title: (p) => ((p.path as string) ?? 'file').split('/').at(-1) ?? 'file',
		icon: 'file',
		dragLabel: (p) => ((p.path as string) ?? 'file').split('/').at(-1) ?? 'file',
		key: (p) => `file:${p.path}`,
		component: FileSurface
	},
	messages: {
		kind: 'messages',
		title: () => 'Messages',
		icon: 'message',
		key: () => 'messages',
		component: MessagesSurface
	}
};
```

Note: `FileSurface`'s current props are `{ tileId, grab }`. In Task 8 it gains `params` for type-compatibility with the registry `Component` type, but it can keep reading the path via `workspaceStore.tilePath(tileId)`. If svelte-check complains here about the prop shape mismatch, defer wiring `file` into the registry until Task 8 (where `FileSurface` is touched) — but define the entry now.

- [ ] **Step 5: Verify**

`cd frontend && bun run check && bun run test && bun run build`. Expected 0/0, 13/13, build ok. `SessionPane` now requires `layout`+`onClose`; its only renderer until Task 8 is `SessionSurface` (Step 2) — but `LegendShell` still renders `<SessionPane session grab>` (Phase 1). So this step WILL fail check until LegendShell is updated. **Therefore: also apply the minimal LegendShell edit** — in the Sessions branch tile snippet, change `<SessionPane session={s} {grab} />` to `<SessionPane session={s} {grab} layout={sessionsLayout.layout} onClose={() => sessionsLayout.evict(id)} />`. (Full registry-driven shell rendering lands in Task 8; this keeps the branch green now.)

- [ ] **Step 6: Commit**
```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/shell/surfaces.ts frontend/src/lib/components/surfaces frontend/src/lib/components/sessions/SessionPane.svelte frontend/src/lib/components/shell/LegendShell.svelte
git commit -m "feat(tiling): surface registry + Session/Messages surfaces; decouple SessionPane"
```

---

## Task 7: Re-verify Sessions/Library parity (decouple guard)

**Files:** none (verification task).

This task exists because Task 6 edited parity-verified Sessions code (`SessionPane`). Confirm no regression before building further.

- [ ] **Step 1:** `cd frontend && bun run check && bun run test && bun run build` — all green.
- [ ] **Step 2:** With `just dev` running, confirm at `localhost:5173`: Sessions space auto-tiles, drag-split with no terminal repaint, eye-zoom/restore, ×-close (evict), keys 1–9; Library space opens + splits files. (Controller runs the live click-through via CDP as in Phase 1; the implementer reports the check/build/test results and notes that live verification is the controller's.)
- [ ] **Step 3:** No commit (no code change). Report status.

---

## Task 8: Generalize `workspaceStore` bindings + registry-driven shell rendering

**Files:**
- Modify: `frontend/src/lib/shell/workspace.svelte.ts`, `frontend/src/lib/components/shell/LegendShell.svelte`, `frontend/src/lib/components/library/FileSurface.svelte`

**Interfaces:**
- Produces on `workspaceStore`: `binding(id): {kind,params}|null`, `openSurface(kind, params)`, `splitActive()`, `setActiveTileParams(params)`, `closeTile(id)`, `tilePath(id)`, `activePath`, `openFile(path)`, `setActiveFile(path)`, plus space CRUD (`createSpace`/`renameSpace`/`deleteSpace` — used by Task 9). `Space` shape per locked decision 3.

- [ ] **Step 1: Rewrite `workspace.svelte.ts`**

`frontend/src/lib/shell/workspace.svelte.ts`:
```ts
// The workspace: a set of Spaces, each a named tiling layout of surfaces.
// Tiles carry {kind, params} bindings resolved through the surface registry.
// The auto Sessions space is special: its tile ids ARE session ids and its
// bindings are derived; all other spaces store manual bindings.

import { TileLayout } from './tiling.svelte';
import { sessionsLayout } from './sessions-layout.svelte';
import { filesStore } from '$lib/stores/files.svelte';
import { SURFACES } from './surfaces';

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
		const existing = lib.layout.tiles.find((id) => this.tilePathIn(id) === path);
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
	private tilePathIn(id: string): string | null {
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
}

export const workspaceStore = new WorkspaceStore();
```

Note: `private tilePathIn` uses the TS `private` keyword on a class method (allowed; not a runes field). If the project's lint prefers `#tilePathIn`, use the `#` private-method form instead — keep it private either way.

- [ ] **Step 2: Update `FileSurface.svelte`** — change the Split handler call `workspaceStore.splitActiveFile()` to `workspaceStore.splitActive()`, and add the uniform `params` prop to its props block (`params?: Record<string, unknown>` — unused; it reads the path via `workspaceStore.tilePath(tileId)`) so its type matches the registry `Component` signature. Keep everything else.

- [ ] **Step 3: Registry-driven tile snippet in `LegendShell.svelte`**

Replace the body-rendering block. Define ONE shared tile snippet and reuse it across the three frame modes. Key parts:
```svelte
	import { SURFACES } from '$lib/shell/surfaces';
	// ... existing imports; REMOVE the SessionPane/FileSurface direct imports if no longer referenced
```
Shared snippet (place before the layout markup):
```svelte
{#snippet surfaceTile(id: string, grab: (e: PointerEvent) => void)}
	{@const b = workspaceStore.binding(id)}
	{@const Surface = b ? SURFACES[b.kind]?.component : undefined}
	{#if Surface}<Surface tileId={id} params={b.params} {grab} />{/if}
{/snippet}
```
Frame markup (replace the Phase 1 `{#if space.kind === 'sessions'}…{:else}…` block):
```svelte
	<div class="flex min-h-0 flex-1">
		{#if space.auto === 'sessions'}
			<SessionBench />
			<div class="min-w-0 flex-1 overflow-hidden bg-app">
				<TileGrid layout={space.layout} dragLabel={(id) => workspaceStore.dragLabel(id)}>
					{#snippet tile(id, grab)}{@render surfaceTile(id, grab)}{/snippet}
					{#snippet empty()}{@render sessionsEmpty()}{/snippet}
				</TileGrid>
			</div>
		{:else if space.rail === 'library'}
			<WorkbenchLayout storageKey={sideOpenKey}>
				{#snippet rail()}<LibraryRail />{/snippet}
				{#snippet primary()}
					<TileGrid layout={space.layout} dragLabel={(id) => workspaceStore.dragLabel(id)}>
						{#snippet tile(id, grab)}{@render surfaceTile(id, grab)}{/snippet}
						{#snippet empty()}{@render libraryEmpty()}{/snippet}
					</TileGrid>
				{/snippet}
				{#snippet side()}<LibrarySide />{/snippet}
			</WorkbenchLayout>
		{:else}
			<div class="min-w-0 flex-1 overflow-hidden bg-app">
				<TileGrid layout={space.layout} dragLabel={(id) => workspaceStore.dragLabel(id)}>
					{#snippet tile(id, grab)}{@render surfaceTile(id, grab)}{/snippet}
					{#snippet empty()}{@render customEmpty()}{/snippet}
				</TileGrid>
			</div>
		{/if}
	</div>
```
Keep the existing `sessionsEmpty` markup (move it into a `{#snippet sessionsEmpty()}`), the `libraryEmpty` markup likewise, and add a `customEmpty` snippet:
```svelte
{#snippet customEmpty()}
	<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
		<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="grid" size={22} /></div>
		<p class="text-title text-ink-2">Empty space.</p>
		<p class="max-w-[260px] text-ui text-ink-3">Open a surface from <kbd class="rounded border border-hair bg-inset px-1 font-mono text-meta">⌘K</kbd> to start tiling.</p>
	</div>
{/snippet}
```
The `SessionPane`/`FileSurface` direct imports in LegendShell are removed (the registry renders them now). Keep `sessionById`/`candidates`/reconcile `$effect`/keyboard handler as-is. The keyboard gate `space.kind !== 'sessions'` becomes `space.auto !== 'sessions'`.

- [ ] **Step 4: Verify** — `cd frontend && bun run check && bun run test && bun run build` (0/0, 13/13, ok).
- [ ] **Step 5: Commit**
```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/shell/workspace.svelte.ts frontend/src/lib/components/shell/LegendShell.svelte frontend/src/lib/components/library/FileSurface.svelte
git commit -m "feat(tiling): {kind,params} bindings + registry-driven shell rendering"
```

---

## Task 9: Launcher (evolve SpacesOverlay)

**Files:**
- Modify: `frontend/src/lib/components/shell/SpacesOverlay.svelte`, `frontend/src/lib/shell/shell.svelte.ts`, `frontend/src/lib/components/shell/LegendShell.svelte` (drop `SpaceSwitcher`, mount `NewSessionDialog` driven by launcher)
- Delete: `frontend/src/lib/components/shell/SpaceSwitcher.svelte`

**Interfaces:**
- `shell.svelte.ts` gains `settingsOpen = $state(false)` + `openSettings()`/`closeSettings()`, and a `newSessionOpen = $state(false)` + `openNewSession()` (the launcher triggers the existing `NewSessionDialog`).

- [ ] **Step 1: Extend `shell.svelte.ts`** — add `settingsOpen`, `newSessionOpen` `$state(false)` fields and `openSettings()`/`closeSettings()`/`openNewSession()` methods (set the flags). Keep `spacesOpen`/pins.

- [ ] **Step 2: Rewrite `SpacesOverlay.svelte` as the launcher.** Sections (reuse the existing `Surface`/`SectionLabel`/search-row chrome):
  - **Spaces**: list `workspaceStore.spaces` (● active highlight via `accent-soft`, click → `switchSpace` + `closeSpaces`); each custom space gets an inline rename (double-click → input) and a delete affordance (two-step, not for seeded spaces). A **"+ New space"** row → `workspaceStore.createSpace()` + close.
  - **Open**: rows — "New session" (→ `shell.openNewSession()` + close), "Open file" (→ switch to Library space + close; the user picks from the tree), "Messages" (→ `workspaceStore.openSurface('messages', {})` + close). Plus a **Running sessions** sublist (from `sessionsStore.sessions`): clicking one → `workspaceStore.openSurface('session', { sessionId: s.id, name: s.name || s.harness_id })` + close (opens an existing session into the active space).
  - **Settings** row → `shell.openSettings()` + close.
  Filter (`query`) matches space names + open-row labels. Keep Esc/backdrop close. Replace all `views.ts`/`goto` navigation with the above store calls.

- [ ] **Step 3: Update `LegendShell.svelte`** — remove the `<SpaceSwitcher />` `center` snippet usage and the import; instead keep the TopBar's existing Spaces pill (opens the launcher) as the nav. Mount the Settings modal and the launcher-driven new-session dialog:
```svelte
	import SettingsModal from './SettingsModal.svelte';
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	...
	<SettingsModal />
	<NewSessionDialog bind:open={shell.newSessionOpen} trigger={false} />
```
(The `center` TopBar slot may stay unused or render nothing — leave the `center?` prop on TopBar for now.)

- [ ] **Step 4: Delete `SpaceSwitcher.svelte`** (`git rm`).
- [ ] **Step 5: Verify + commit** — `bun run check && bun run test && bun run build`; commit `feat(tiling): launcher (spaces + open surface + settings) replacing SpaceSwitcher`.

---

## Task 10: Settings modal (shadcn Dialog)

**Files:**
- Create: `frontend/src/lib/components/shell/SettingsModal.svelte`

**Interfaces:**
- Consumes: `shell.settingsOpen` (Task 9), shadcn `Dialog`, the existing settings logic from `routes/settings/+page.svelte`.

- [ ] **Step 1: Create `SettingsModal.svelte`.** Move the entire `<script>` logic AND the `<section>` markup from `frontend/src/routes/settings/+page.svelte` into this component VERBATIM (the library-path form + harness-integrations list, `getLibraryPath`/`putLibraryPath`/`resetLibraryPath`/`listHarnesses`/`applyHarnessSetup`, all `$state`, `onMount(load+loadHarnesses)`). Wrap it in a shadcn `Dialog` bound to `shell.settingsOpen`:
```svelte
<script lang="ts">
	import * as Dialog from '$lib/components/ui/dialog';
	import { shell } from '$lib/shell/shell.svelte';
	// ... (all the imports + logic copied from routes/settings/+page.svelte) ...
</script>

<Dialog.Root bind:open={shell.settingsOpen}>
	<Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
		<Dialog.Header>
			<Dialog.Title>Settings</Dialog.Title>
			<Dialog.Description>Workspace & harness integrations</Dialog.Description>
		</Dialog.Header>
		<!-- the <section> blocks from the old settings page (drop the outer page <div> + <h1>) -->
	</Dialog.Content>
</Dialog.Root>
```
Keep `onMount` loading (the Dialog mounts with the shell, so data loads once). If you prefer lazy loading, gate `load()` behind `$effect(() => { if (shell.settingsOpen && !loaded) … })` — but the simple `onMount` is acceptable. No `window.confirm` (the existing two-step `confirmingReset` is in-UI — keep it).

- [ ] **Step 2: Mount it** — already added to `LegendShell` in Task 9 Step 3 (`<SettingsModal />`). Verify it's there.
- [ ] **Step 3: Verify + commit** — `bun run check && bun run test && bun run build`; commit `feat(tiling): Settings modal (shadcn Dialog)`.

---

## Task 11: Route collapse / deep-link redirects

**Files:**
- Modify: `frontend/src/routes/library/+page.svelte`, `frontend/src/routes/messages/+page.svelte`, `frontend/src/routes/settings/+page.svelte`, `frontend/src/routes/sessions/[id]/+page.svelte`

Navigation now lives in the workspace, not routes. Each legacy route triggers the equivalent workspace action on mount and normalizes the URL to `/`.

- [ ] **Step 1: `routes/library/+page.svelte`**:
```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	onMount(() => { workspaceStore.switchSpace('library'); void goto('/'); });
</script>
```

- [ ] **Step 2: `routes/messages/+page.svelte`** — same shape, body: `workspaceStore.openSurface('messages', {}); void goto('/');`.

- [ ] **Step 3: `routes/settings/+page.svelte`** — same shape, importing `shell`; body: `shell.openSettings(); void goto('/');`.

- [ ] **Step 4: `routes/sessions/[id]/+page.svelte`** — read the id from `page.params`, then `sessionsLayout.promote(id); workspaceStore.switchSpace('sessions'); void goto('/');` (focuses that session's tile). Use `import { page } from '$app/state'` and `onMount`.

- [ ] **Step 5: Verify + commit** — `bun run check && bun run test && bun run build`; manual: visiting `/library`, `/messages`, `/settings`, `/sessions/<id>` lands on the right space/surface/modal. Commit `feat(tiling): collapse legacy routes into workspace actions`.

---

## Task 12: Workspace persistence (adapter + localStorage, tolerant load)

**Files:**
- Create: `frontend/src/lib/shell/workspace-persistence.ts`
- Modify: `frontend/src/lib/shell/workspace.svelte.ts` (snapshot + hydrate), `frontend/src/lib/components/shell/LegendShell.svelte` (hydrate on mount + reactive save)

**Interfaces:**
- Produces: `WorkspacePersistence` interface, `localStoragePersistence`; `workspaceStore.snapshot()` and `workspaceStore.hydrate(snap)`.

- [ ] **Step 1: Create `workspace-persistence.ts`**:
```ts
import type { LayoutSnapshot } from './tiling-core';

export const WORKSPACE_SCHEMA = 1;

export interface SpaceSnapshot {
	id: string;
	name: string;
	auto?: 'sessions';
	rail?: 'library';
	side?: 'library';
	layout: LayoutSnapshot;
	bindings: Array<{ id: string; kind: string; params: Record<string, unknown> }>;
}

export interface WorkspaceSnapshot {
	version: number;
	activeId: string;
	dismissed: string[];
	spaces: SpaceSnapshot[];
}

export interface WorkspacePersistence {
	load(): WorkspaceSnapshot | null;
	save(snap: WorkspaceSnapshot): void;
}

const KEY = 'legend:workspace';

export const localStoragePersistence: WorkspacePersistence = {
	load() {
		if (typeof localStorage === 'undefined') return null;
		try {
			const raw = localStorage.getItem(KEY);
			if (!raw) return null;
			const snap = JSON.parse(raw) as WorkspaceSnapshot;
			if (snap.version !== WORKSPACE_SCHEMA) return null; // tolerant: reset on mismatch
			return snap;
		} catch {
			return null;
		}
	},
	save(snap) {
		if (typeof localStorage === 'undefined') return;
		try {
			localStorage.setItem(KEY, JSON.stringify(snap));
		} catch {
			// non-fatal: quota / disabled storage
		}
	}
};
```

- [ ] **Step 2: Add `snapshot()` + `hydrate()` to `workspaceStore`.** `snapshot()` reads the reactive state (so a `$effect` calling it tracks changes) and returns a `WorkspaceSnapshot`: for each NON-auto space, `{id,name,rail,side, layout: space.layout.serialize(), bindings: space.layout.tiles.map(id => ({id, ...#bindings[id]})).filter(b=>b.kind)}`; the auto Sessions space is recorded with `auto:'sessions'` and an EMPTY layout/bindings (it repopulates from live sessions). Include `activeId`, `dismissed: sessionsLayout.dismissedIds()` (add a getter on `sessionsLayout` returning `[...#dismissed]`), and `version: WORKSPACE_SCHEMA`.
  `hydrate(snap)`: if `snap` is null, keep seeded defaults. Else rebuild: for each snapshot space, if `auto` keep the live sessions space; else create a `Space` with a fresh `TileLayout`, `deserialize(space.layout)`, and restore `#bindings` for its tiles — **dropping any binding whose `kind` is not in `SURFACES`** (tolerant). Restore `activeId` (fall back to `'sessions'` if missing). Restore `sessionsLayout` dismissals. Lazy-load any `file` bindings' buffers (`filesStore.load(path)`), tolerating missing files (load already routes errors to `filesStore.error`; the tile shows the FileSurface empty/missing state).

- [ ] **Step 3: Wire in `LegendShell`** — in `onMount` (add `import { onMount } from 'svelte'`): `workspaceStore.hydrate(localStoragePersistence.load());` then set a local `hydrated = true`. Add a reactive save:
```svelte
	$effect(() => {
		const snap = workspaceStore.snapshot();
		if (hydrated) localStoragePersistence.save(snap);
	});
```
(`snapshot()` reads the reactive state, so the effect re-runs and saves on any change; the `hydrated` guard avoids clobbering storage with defaults before load.)

- [ ] **Step 4: Verify + commit** — `bun run check && bun run test && bun run build`; manual: open files / create a custom space with a messages tile, reload → spaces + tiles restored; delete a file that a persisted tile referenced, reload → tile shows missing state, no crash. Commit `feat(tiling): localStorage workspace persistence (versioned, tolerant) via adapter`.

---

## Task 13: Docs — VISION / ARCHITECTURE / DESIGN_SYSTEM + retire views.ts

**Files:**
- Modify: `docs/VISION.md`, `docs/ARCHITECTURE.md`, `docs/DESIGN_SYSTEM.md`
- Delete: `frontend/src/lib/shell/views.ts` (after confirming no readers remain)

- [ ] **Step 1: Confirm `views.ts` has no readers** — `grep -rn "shell/views" frontend/src`. If `TopBar`/`LegendShell` still import `viewById`/`sectionForPath` for the chip/sub/count, replace those reads with the active space's name/icon (`workspaceStore.active`) and remove the imports, THEN `git rm frontend/src/lib/shell/views.ts`. If any reader can't be cleanly removed, leave `views.ts` and note it (don't force it).

- [ ] **Step 2: `VISION.md`** — under "Product principles" §4 (plugins) or the architecture spine, add a short paragraph: tiling is the windowing core of the app; *surfaces* (session, file, messages, later calendar/email) are the concrete form of the "UI panels are extension points" principle; *spaces* are named, user- (and later agent-) arrangeable tiling workspaces; the launcher's `openSurface` API is the seam an agent uses to arrange the UI. (Vision changes go in first per its own preamble.)

- [ ] **Step 3: `ARCHITECTURE.md`** — add a "Windowing core / workspace" section recording: `TileLayout` (opaque-id model) + `tiling-core` (pure, tested) + flat-positioned `TileGrid` (render-once, no remount); the surface registry (`surfaces.ts`); the Space model + auto Sessions space (relocated watch-set logic: cap/dismiss/reconcile now in `sessions-layout.svelte.ts`); `SessionPane` decoupled via `layout`+`onClose`; the modal layer (shadcn `Dialog`, Settings); the persistence adapter seam (localStorage now, SQLite/sync later) with versioned tolerant load; route collapse. Note the accepted caveats (auto Sessions space is sessions-only; file buffers shared by path).

- [ ] **Step 4: `DESIGN_SYSTEM.md`** — add `TileGrid` and the space-frame composition (bench-direct vs `WorkbenchLayout` vs grid-only) as first-class shell primitives alongside `WorkbenchLayout`/`SidePane`; document the flat-positioned rendering contract.

- [ ] **Step 5: Commit** — `git add docs frontend/src` (+ the `views.ts` removal if done); commit `docs: tiling workspace — VISION/ARCHITECTURE/DESIGN_SYSTEM + retire views.ts`.

---

## Self-Review (Phase 2)

**Spec coverage:** surface registry (T6) ✓; SessionPane decouple enabling session surfaces anywhere + parity re-verify (T6/T7) ✓; `{kind,params}` bindings + registry-driven rendering + custom spaces (T8) ✓; launcher with spaces + open-surface + running-sessions + settings (T9) ✓; modal layer via shadcn Dialog + Settings (T10) ✓; route collapse (T11) ✓; versioned/tolerant localStorage persistence via adapter (T12) ✓; docs + views.ts retire (T13) ✓. Matches the spec's Phase 2 outline and "OS workspace" goal; calendar/email/agent-driven-layout/backend-sync remain out of scope per the spec's non-goals.

**Placeholder scan:** No TBD/TODO. The two "verbatim extract" tasks (MessagesSurface from messages page T6.3; SettingsModal from settings page T10.1) reference exact existing source the implementer copies; the docs task gives concrete content per file. Component tasks state their verification (check/build + the controller's live CDP parity for T7).

**Type consistency:** Surface component contract `{tileId, params, grab}` is uniform across `SessionSurface`/`FileSurface`/`MessagesSurface` and the `SurfaceDef.component` type (T6, T8). `SessionPane` props `{session,grab,layout,onClose}` are produced in T6.1 and consumed by `SessionSurface` (T6.2) and the shell's Sessions branch (T6.5 / T8.3). `workspaceStore` methods (`binding`/`openSurface`/`splitActive`/`setActiveTileParams`/`closeTile`/`tilePath`/`activePath`/`openFile`/`setActiveFile`/`createSpace`/`renameSpace`/`deleteSpace`/`dragLabel`/`snapshot`/`hydrate`) are defined in T8/T12 and consumed by the launcher (T9), FileSurface (T8.2), routes (T11), and shell (T8.3/T12.3). `Space` shape (`auto`/`rail`/`side`) is consistent T8↔T12. `LayoutSnapshot` (from Phase 1 `tiling-core`) is reused by the persistence snapshot (T12.1). One dependency to honor: `sessionsLayout` must expose `dismissedIds()` for T12.2 — add it in T12 (it currently keeps `#dismissed` private).

