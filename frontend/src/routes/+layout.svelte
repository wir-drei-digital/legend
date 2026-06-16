<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import LegendShell from '$lib/components/shell/LegendShell.svelte';

	let { children } = $props();
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

<LegendShell>
	{@render children()}
</LegendShell>
