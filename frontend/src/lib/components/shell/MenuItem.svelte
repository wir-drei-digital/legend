<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon, { type IconName } from './Icon.svelte';
	let {
		icon,
		tone = 'default',
		onclick,
		disabled = false,
		children
	}: {
		icon?: IconName;
		tone?: 'default' | 'danger';
		onclick?: () => void;
		disabled?: boolean;
		children: Snippet;
	} = $props();
</script>

<button
	type="button"
	{disabled}
	{onclick}
	class="flex w-full items-center gap-2 px-2.5 text-left text-ui transition-colors disabled:opacity-40 {tone === 'danger' ? 'text-[var(--red)] hover:bg-[color-mix(in_oklab,var(--red)_14%,transparent)]' : 'text-ink-2 hover:bg-[var(--hover-tint)] hover:text-ink-1'}"
	style:height="var(--h-row)"
>
	{#if icon}<Icon name={icon} size={13} class={tone === 'danger' ? '' : 'text-ink-3'} />{/if}
	{@render children()}
</button>
