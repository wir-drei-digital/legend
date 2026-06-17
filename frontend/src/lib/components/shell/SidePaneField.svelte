<script lang="ts">
	let { label, value }: { label: string; value: string } = $props();
</script>

<div class="flex items-baseline justify-between gap-3 text-ui">
	<span class="shrink-0 text-ink-3">{label}</span>
	<span class="min-w-0 truncate text-ink-1" title={value}>{value}</span>
</div>
