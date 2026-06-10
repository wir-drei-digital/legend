<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();

	// True inside the Tauri webview (desktop app), false in the browser.
	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>
{#if isTauri}
	<!-- Title bar stand-in: the macOS traffic lights overlay this strip
	     (titleBarStyle: Overlay); it doubles as the window drag handle. -->
	<header data-tauri-drag-region class="h-10 w-full shrink-0 select-none"></header>
{/if}
{@render children()}
