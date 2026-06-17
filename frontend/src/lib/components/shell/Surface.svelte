<script lang="ts">
	import type { Snippet } from 'svelte';
	let {
		elevation = 'pop',
		class: className = '',
		children
	}: { elevation?: 'pop' | 'overlay'; class?: string; children: Snippet } = $props();
</script>

<div
	class="overflow-hidden rounded-[10px] border border-hair-strong bg-panel {elevation === 'overlay' ? 'shadow-overlay' : 'shadow-pop'} {className}"
>
	{@render children()}
</div>
