<script lang="ts">
	import Icon from './Icon.svelte';
	import { Button } from '$lib/components/ui/button';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';

	let { isTauri = false }: { isTauri?: boolean } = $props();

	const space = $derived(workspaceStore.active);
	const count = $derived(space.layout.tileCount || undefined);
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

	<!-- Spaces switcher: the entire navigation footprint. Shows the active space. -->
	<button
		type="button"
		onclick={() => shell.toggleSpaces()}
		aria-expanded={shell.spacesOpen}
		class="flex h-[30px] shrink-0 items-center gap-2 rounded-full border border-hair-strong bg-raised pl-2.5 pr-2 transition-colors hover:border-[color-mix(in_oklab,var(--accent-hi)_30%,var(--border-strong))]"
	>
		<Icon name={space.icon} size={15} class="text-brand-hi" />
		<span class="text-title font-semibold text-ink-1">{space.name}</span>
		{#if count !== undefined}
			<span class="font-mono text-ui text-ink-3">{count}</span>
		{/if}
		<Icon name="chevron-down" size={14} class="text-ink-3" />
	</button>

	<div class="flex-1"></div>

	<Button size="sm" class="h-[30px] px-3" onclick={() => shell.openNewSession()}>New session</Button>
</header>
