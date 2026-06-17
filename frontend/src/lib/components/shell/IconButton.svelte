<script lang="ts">
	import Icon, { type IconName } from './Icon.svelte';

	let {
		icon,
		size = 14,
		box = 24,
		title,
		onclick,
		active = false,
		tone = 'default',
		disabled = false,
		class: className = ''
	}: {
		icon: IconName;
		size?: number;
		box?: number;
		title?: string;
		onclick?: (e: MouseEvent) => void;
		active?: boolean;
		tone?: 'default' | 'accent' | 'danger';
		disabled?: boolean;
		class?: string;
	} = $props();

	const hover = $derived(
		tone === 'danger'
			? 'hover:bg-[color-mix(in_oklab,var(--red)_14%,transparent)] hover:text-bad'
			: 'hover:bg-[var(--hover-tint)] hover:text-ink-2'
	);
	const activeColor = $derived(tone === 'accent' ? 'var(--accent-hi)' : 'var(--text-1)');
</script>

<button
	type="button"
	{title}
	{disabled}
	{onclick}
	class="grid shrink-0 place-items-center rounded-md text-ink-3 transition-colors disabled:opacity-40 disabled:hover:bg-transparent {hover} {className}"
	style:width="{box}px"
	style:height="{box}px"
	style:color={active ? activeColor : undefined}
>
	<Icon name={icon} {size} />
</button>
