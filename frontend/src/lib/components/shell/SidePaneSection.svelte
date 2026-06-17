<script lang="ts">
	import type { Snippet } from 'svelte';
	let { label, children }: { label: string; children: Snippet } = $props();
</script>

<section class="flex flex-col gap-2">
	<h3 class="font-mono text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-3">{label}</h3>
	{@render children()}
</section>
