<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import LegendShell from '$lib/components/shell/LegendShell.svelte';
	import MobileShell from '$lib/components/mobile/MobileShell.svelte';
	import { isMobile } from '$lib/remote/viewport.svelte';

	let { children } = $props();

	// /pair is a standalone, shell-less screen (pre-auth, phone-width).
	const bare = $derived(page.route.id === '/pair');
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

{#if bare}
	{@render children()}
{:else if isMobile.current}
	<MobileShell />
{:else}
	<LegendShell>
		{@render children()}
	</LegendShell>
{/if}
