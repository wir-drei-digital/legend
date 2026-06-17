<script lang="ts">
	import type { Snippet } from 'svelte';
	let { class: className = '', children }: { class?: string; children: Snippet } = $props();
</script>

<span
	class="font-mono text-micro font-semibold uppercase tracking-[0.14em] text-ink-3 {className}"
>
	{@render children()}
</span>
