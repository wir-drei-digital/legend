<script lang="ts">
	import { identityFor } from '$lib/shell/identities';

	// Solid fill of the identity color, white text, no border, squircle (radius 32%).
	// `soft` = a quieter 18% tint + colored border + colored letter for dense lists.
	let {
		harnessId,
		size = 20,
		soft = false,
		class: className = ''
	}: { harnessId: string; size?: number; soft?: boolean; class?: string } = $props();

	const identity = $derived(identityFor(harnessId));
	const color = $derived(`var(${identity.colorVar})`);
</script>

<span
	class="inline-grid shrink-0 place-items-center font-semibold leading-none {className}"
	class:border={soft}
	style:width="{size}px"
	style:height="{size}px"
	style:border-radius="32%"
	style:font-size="{Math.round(size * 0.46)}px"
	style:background={soft ? `color-mix(in oklab, ${color} 18%, transparent)` : color}
	style:color={soft ? color : '#fff'}
	style:border-color={soft ? color : 'transparent'}
	title={identity.label}
>
	{identity.tag}
</span>
