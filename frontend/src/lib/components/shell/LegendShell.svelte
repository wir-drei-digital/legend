<script lang="ts">
	import type { Snippet } from 'svelte';
	import { onMount } from 'svelte';
	import TopBar from './TopBar.svelte';
	import StatusBar from './StatusBar.svelte';
	import SpacesOverlay from './SpacesOverlay.svelte';
	import SettingsModal from './SettingsModal.svelte';
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	import WorkbenchLayout from './WorkbenchLayout.svelte';
	import TileGrid from './TileGrid.svelte';
	import Icon from './Icon.svelte';
	import SessionBench from '$lib/components/sessions/SessionBench.svelte';
	import LibraryRail from '$lib/components/library/LibraryRail.svelte';
	import LibrarySide from '$lib/components/library/LibrarySide.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { localStoragePersistence } from '$lib/shell/workspace-persistence';
	import { SURFACES } from '$lib/shell/surfaces';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { liveState } from '$lib/shell/sessionState';

	let { children }: { children: Snippet } = $props();

	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

	const space = $derived(workspaceStore.active);
	const sideOpenKey = $derived(`legend:space:${space.id}:side`);

	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});

	// Workspace persistence: hydrate once on mount, then reactively save. The
	// `hydrated` guard prevents clobbering storage with defaults before load.
	let hydrated = $state(false);
	onMount(() => {
		workspaceStore.hydrate(localStoragePersistence.load());
		hydrated = true;
	});
	let saveTimer: ReturnType<typeof setTimeout> | undefined;
	$effect(() => {
		const snap = workspaceStore.snapshot(); // keep this read so the effect tracks workspace changes
		if (!hydrated) return;
		clearTimeout(saveTimer);
		saveTimer = setTimeout(() => localStoragePersistence.save(snap), 300);
	});

	// Sessions auto-tile: keep the watch-set consistent with live sessions.
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
		if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
			e.preventDefault();
			shell.toggleSpaces();
			return;
		}
		const el = e.target as HTMLElement | null;
		if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
		if (shell.spacesOpen || space.auto !== 'sessions') return;
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
	<TopBar {isTauri} />

	{#snippet surfaceTile(id: string, grab: (e: PointerEvent) => void)}
		{@const b = workspaceStore.binding(id)}
		{@const Surface = b ? SURFACES[b.kind]?.component : undefined}
		{#if b && Surface}<Surface tileId={id} params={b.params} {grab} />{/if}
	{/snippet}

	{#snippet sessionsEmpty()}
		<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
			<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="sessions" size={22} /></div>
			<p class="text-title text-ink-2">{sessionsStore.sessions.length === 0 ? 'No sessions running.' : 'No tiles in the grid.'}</p>
			<p class="max-w-[260px] text-ui text-ink-3">{sessionsStore.sessions.length === 0 ? 'Use New session in the top bar to launch an agent.' : 'Promote a session from the bench on the left to watch it here.'}</p>
		</div>
	{/snippet}

	{#snippet libraryEmpty()}
		<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
			<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="folder" size={22} /></div>
			<p class="text-title text-ink-2">No file open.</p>
			<p class="max-w-[260px] text-ui text-ink-3">Pick a file from the Explorer on the left to open it here.</p>
		</div>
	{/snippet}

	{#snippet customEmpty()}
		<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
			<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="grid" size={22} /></div>
			<p class="text-title text-ink-2">Empty space.</p>
			<p class="max-w-[260px] text-ui text-ink-3">Open a surface from <kbd class="rounded border border-hair bg-inset px-1 font-mono text-meta">⌘K</kbd> to start tiling.</p>
		</div>
	{/snippet}

	<div class="flex min-h-0 flex-1">
		{#if space.auto === 'sessions'}
			<!-- Sessions renders bench + grid directly (SessionBench owns its own
			     178px aside + border) — matches today's shell exactly for parity. -->
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

	<StatusBar />

	{#if shell.spacesOpen}
		<SpacesOverlay />
	{/if}

	<NewSessionDialog bind:open={shell.newSessionOpen} trigger={false} />

	<SettingsModal />
</div>
