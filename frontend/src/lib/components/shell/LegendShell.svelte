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
			<!-- Sessions renders bench + grid directly (SessionBench owns its own
			     178px aside + border) — matches today's shell exactly for parity. -->
			<SessionBench />
			<div class="min-w-0 flex-1 overflow-hidden bg-app">
				<TileGrid layout={space.layout} dragLabel={sessionLabel}>
					{#snippet tile(id, grab)}
						{@const s = sessionById.get(id)}
						{#if s}<SessionPane session={s} {grab} layout={sessionsLayout.layout} onClose={() => sessionsLayout.evict(id)} />{/if}
					{/snippet}
					{#snippet empty()}
						<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
							<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3"><Icon name="sessions" size={22} /></div>
							<p class="text-title text-ink-2">{sessionsStore.sessions.length === 0 ? 'No sessions running.' : 'No tiles in the grid.'}</p>
							<p class="max-w-[260px] text-ui text-ink-3">{sessionsStore.sessions.length === 0 ? 'Use New session in the toolbar to launch an agent.' : 'Promote a session from the bench on the left to watch it here.'}</p>
						</div>
					{/snippet}
				</TileGrid>
			</div>
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
