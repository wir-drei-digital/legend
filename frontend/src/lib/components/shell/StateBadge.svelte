<script lang="ts">
	// Tiny right-aligned pane/bench badge. NEW = new unread output (accent),
	// ASK = needs input (amber), ERR = errored (red). 9px/700, letterspaced.
	let { kind, count }: { kind: 'new' | 'ask' | 'err'; count?: number } = $props();

	const color = $derived(
		kind === 'new' ? 'var(--accent-hi)' : kind === 'ask' ? 'var(--amber)' : 'var(--red)'
	);
	const text = $derived(kind === 'new' ? `NEW${count ? ' ' + count : ''}` : kind.toUpperCase());
</script>

<span
	class="inline-flex items-center gap-1 font-mono font-bold uppercase tracking-[0.08em]"
	style:color
	style:font-size="9px"
>
	{#if kind === 'new'}
		<span class="size-[3px] rounded-full" style:background={color}></span>
	{:else}
		<!-- alert glyph -->
		<svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke={color} stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
			<path d="M12 3L2 20h20L12 3z" />
			<path d="M12 10v4" />
			<path d="M12 17.5v.01" />
		</svg>
	{/if}
	{text}
</span>
