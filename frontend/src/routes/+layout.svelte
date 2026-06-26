<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import LegendShell from '$lib/components/shell/LegendShell.svelte';

	let { children } = $props();

	// /pair is a standalone, shell-less screen (pre-auth, phone-width).
	const bare = $derived(page.route.id === '/pair');
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

{#if bare}
	{@render children()}
{:else}
	<LegendShell>
		{@render children()}
	</LegendShell>
{/if}
