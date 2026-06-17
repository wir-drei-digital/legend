<script lang="ts">
	import type { Snippet } from 'svelte';
	import SectionLabel from './SectionLabel.svelte';
	let { label, children }: { label: string; children: Snippet } = $props();
</script>

<section class="flex flex-col gap-2">
	<SectionLabel>{label}</SectionLabel>
	{@render children()}
</section>
