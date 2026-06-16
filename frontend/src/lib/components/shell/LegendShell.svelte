<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import TopBar from './TopBar.svelte';
	import StatusBar from './StatusBar.svelte';
	import SpacesOverlay from './SpacesOverlay.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { sectionForPath, viewById } from '$lib/shell/views';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let { children }: { children: Snippet } = $props();

	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

	const section = $derived(sectionForPath(page.url.pathname));
	const view = $derived(viewById(section));

	// The shell is view-agnostic: it renders whatever chrome the active view
	// declares in the registry (bench rail, toolbar, sub line, chip count).
	const Bench = $derived(view?.bench);
	const subText = $derived(view?.sub?.() ?? '');
	const chipCount = $derived(view?.count?.());

	// Keep the live stores connected for the whole app lifetime.
	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});

	function onKeydown(e: KeyboardEvent) {
		if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
			e.preventDefault();
			shell.toggleSpaces();
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

<!-- Full-bleed: the OS already provides the window frame, so no outer border,
     padding or void background — the shell fills the viewport edge to edge. -->
<div class="relative flex h-dvh w-full flex-col overflow-hidden bg-shell">
	<TopBar {section} sub={subText} count={chipCount} {isTauri} toolbar={view?.toolbar} />

	<div class="flex min-h-0 flex-1">
		{#if Bench}
			<Bench />
		{/if}
		<div class="min-w-0 flex-1 overflow-hidden bg-app">
			{@render children()}
		</div>
	</div>

	<StatusBar />

	{#if shell.spacesOpen}
		<SpacesOverlay />
	{/if}
</div>
