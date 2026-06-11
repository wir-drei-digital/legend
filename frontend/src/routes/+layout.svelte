<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import SessionSidebar from '$lib/components/SessionSidebar.svelte';

	let { children } = $props();

	// True inside the Tauri webview (desktop app), false in the browser.
	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

<div class="flex h-dvh flex-col">
	{#if isTauri}
		<!-- Title bar stand-in: the macOS traffic lights overlay this strip
		     (titleBarStyle: Overlay); it doubles as the window drag handle. -->
		<header data-tauri-drag-region class="h-10 w-full shrink-0 select-none"></header>
	{/if}
	<div class="flex min-h-0 flex-1">
		<SessionSidebar />
		<main class="min-w-0 flex-1">{@render children()}</main>
	</div>
</div>
