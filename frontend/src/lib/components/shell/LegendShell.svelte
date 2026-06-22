<script lang="ts">
	import type { Snippet } from 'svelte';
	import { onMount } from 'svelte';
	import TopBar from './TopBar.svelte';
	import StatusBar from './StatusBar.svelte';
	import SpacesOverlay from './SpacesOverlay.svelte';
	import SettingsModal from './SettingsModal.svelte';
	import RenameSpaceModal from './RenameSpaceModal.svelte';
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	import Dock from './Dock.svelte';
	import TileGrid from './TileGrid.svelte';
	import AsteroidsGame from './AsteroidsGame.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { localStoragePersistence } from '$lib/shell/workspace-persistence';
	import { SURFACES } from '$lib/shell/surfaces';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let { children }: { children: Snippet } = $props();

	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

	const space = $derived(workspaceStore.active);

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

	// Sessions auto-tile: keep the Sessions space consistent with live sessions.
	const liveSessionIds = $derived(sessionsStore.sessions.map((s) => s.id));
	$effect(() => {
		workspaceStore.reconcileSessions(liveSessionIds);
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

	{#snippet emptyState()}
		<AsteroidsGame>
			<p class="text-ui text-ink-2">This space is empty.</p>
			<p class="max-w-[320px] text-meta text-ink-3">Click or drag a file or session from the dock on the left to open it here.</p>
		</AsteroidsGame>
	{/snippet}

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

	<StatusBar />

	{#if shell.spacesOpen}
		<SpacesOverlay />
	{/if}

	<NewSessionDialog bind:open={shell.newSessionOpen} trigger={false} />

	<SettingsModal />

	<RenameSpaceModal />
</div>
