<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon, { type IconName } from './Icon.svelte';

	let {
		title,
		icon,
		onClose,
		onPin,
		pinned = false,
		actions,
		children,
		footer
	}: {
		title: string;
		icon?: IconName;
		onClose?: () => void;
		onPin?: () => void;
		pinned?: boolean;
		actions?: Snippet;
		children: Snippet;
		footer?: Snippet;
	} = $props();
</script>

<aside class="flex h-full min-h-0 w-full flex-col bg-shell">
	<!-- header -->
	<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair px-3">
		{#if icon}<Icon name={icon} size={14} class="shrink-0 text-ink-3" />{/if}
		<span class="min-w-0 flex-1 truncate text-[11.5px] font-semibold text-ink-2">{title}</span>
		{#if actions}{@render actions()}{/if}
		{#if onPin}
			<button
				type="button"
				onclick={onPin}
				title={pinned ? 'Unpin' : 'Pin'}
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
				class:text-brand-hi={pinned}
			>
				<Icon name="star" size={13} fill={pinned} />
			</button>
		{/if}
		{#if onClose}
			<button
				type="button"
				onclick={onClose}
				title="Close panel"
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
			>
				<Icon name="close" size={13} />
			</button>
		{/if}
	</div>

	<!-- body -->
	<div class="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-3 py-3.5">
		{@render children()}
	</div>

	{#if footer}
		<div class="shrink-0 border-t border-hair p-2.5">
			{@render footer()}
		</div>
	{/if}
</aside>
