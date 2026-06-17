<script lang="ts">
	import type { Component } from 'svelte';
	import Icon from './Icon.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { viewById } from '$lib/shell/views';

	let {
		section,
		sub,
		count,
		isTauri = false,
		toolbar
	}: {
		section: string;
		sub?: string;
		count?: number;
		isTauri?: boolean;
		toolbar?: Component;
	} = $props();

	const view = $derived(viewById(section));
	const Toolbar = $derived(toolbar);
</script>

<header
	data-tauri-drag-region={isTauri ? '' : undefined}
	class="flex h-[46px] shrink-0 select-none items-center gap-2.5 border-b border-hair bg-shell px-3.5"
>
	{#if isTauri}
		<!-- Desktop: reserve room for the real macOS traffic lights (titleBarStyle:
		     Overlay). Their top padding is set via trafficLightPosition in Tauri. -->
		<div class="h-full w-[60px] shrink-0" data-tauri-drag-region></div>
	{:else}
		<!-- Web: no OS handles — show the brand mark instead. -->
		<div class="flex shrink-0 items-center gap-2 pl-0.5">
			<span
				class="size-[20px] shrink-0 rounded-[6px] ring-1 ring-[var(--border-strong)]"
				style:background="linear-gradient(135deg, var(--accent-hi), var(--accent) 70%)"
			></span>
			<span class="text-title font-semibold tracking-tight text-ink-1">Legend</span>
		</div>
	{/if}

	<!-- Spaces switcher: the entire navigation footprint. -->
	<button
		type="button"
		onclick={() => shell.toggleSpaces()}
		aria-expanded={shell.spacesOpen}
		class="flex h-[30px] shrink-0 items-center gap-2 rounded-full border border-hair-strong bg-raised pl-2.5 pr-2 transition-colors hover:border-[color-mix(in_oklab,var(--accent-hi)_30%,var(--border-strong))]"
	>
		{#if view}<Icon name={view.icon} size={15} class="text-brand-hi" />{/if}
		<span class="text-title font-semibold text-ink-1">{view?.label ?? section}</span>
		{#if count !== undefined && count > 0}
			<span class="font-mono text-ui text-ink-3">{count}</span>
		{/if}
		<Icon name="chevron-down" size={14} class="text-ink-3" />
	</button>

	{#if sub}
		<span class="min-w-0 truncate text-ui text-ink-3">{sub}</span>
	{/if}

	<div class="flex-1"></div>

	{#if Toolbar}
		<div class="flex shrink-0 items-center gap-2"><Toolbar /></div>
	{/if}
</header>
