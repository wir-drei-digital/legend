<script lang="ts">
	// Reusable status-bar budget indicator. Renders nothing until a real budget
	// source exists — pass `spent`/`total` (USD) once cost tracking lands.
	let {
		spent,
		total,
		segments = 5
	}: { spent?: number; total?: number; segments?: number } = $props();

	const ready = $derived(spent !== undefined && total !== undefined && total > 0);
	const filled = $derived(
		ready ? Math.min(segments, Math.round((spent! / total!) * segments)) : 0
	);
</script>

{#if ready}
	<span class="flex items-center gap-1.5 text-ink-3" title="Budget used">
		budget
		<span class="flex items-center gap-[2px]">
			{#each Array(segments) as _, i (i)}
				<span
					class="h-[9px] w-[5px] rounded-[1px]"
					style:background={i < filled ? 'var(--accent)' : 'var(--bg-raised)'}
				></span>
			{/each}
		</span>
		<span class="text-ink-2">${spent!.toFixed(2)}</span>
	</span>
{/if}
