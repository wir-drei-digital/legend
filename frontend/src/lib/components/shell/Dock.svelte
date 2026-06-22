<script lang="ts">
	import { onMount } from 'svelte';
	import Icon from './Icon.svelte';
	import IconButton from './IconButton.svelte';
	import { Button } from '$lib/components/ui/button';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { DOCK_SOURCES } from '$lib/shell/dock-sources';

	// The left nav. Hosts the brand + spaces switcher + New session at the top
	// (merged from the former full-width top bar so the tile canvas reaches the
	// window's top edge), then the pluggable source sections below.
	let { isTauri = false }: { isTauri?: boolean } = $props();

	const space = $derived(workspaceStore.active);
	const count = $derived(space.layout.tileCount || undefined);

	let collapsed = $state(false); // whole dock
	let openSections = $state<Record<string, boolean>>(
		Object.fromEntries(DOCK_SOURCES.map((s) => [s.id, true]))
	);
	let hydrated = $state(false);

	onMount(() => {
		try {
			const raw = localStorage.getItem('legend:dock');
			if (raw) {
				const v = JSON.parse(raw);
				if (typeof v.collapsed === 'boolean') collapsed = v.collapsed;
				if (v.openSections) openSections = { ...openSections, ...v.openSections };
			}
		} catch {
			/* ignore corrupt */
		}
		hydrated = true;
	});
	$effect(() => {
		if (!hydrated) return;
		try {
			localStorage.setItem('legend:dock', JSON.stringify({ collapsed, openSections }));
		} catch {
			/* non-fatal */
		}
	});
</script>

{#if collapsed && !isTauri}
	<!-- Collapsed rail (web only — desktop stays expanded so the OS traffic lights
	     never overflow a 36px rail). -->
	<div class="flex w-9 shrink-0 flex-col items-center gap-2 border-r border-hair bg-shell pt-2.5">
		<!-- Desktop shows the OS traffic lights instead of the logo; reserve their height. -->
		{#if isTauri}
			<div class="h-[44px] w-full shrink-0" data-tauri-drag-region></div>
		{:else}
			<span
				class="grid size-[20px] shrink-0 place-items-center rounded-[6px] bg-brand text-ui font-semibold leading-none ring-1 ring-[var(--border-strong)]"
				style:color="var(--accent-contrast)"
				aria-hidden="true">L</span>
		{/if}
		<IconButton icon="panel-right" title="Expand dock" onclick={() => (collapsed = false)} />
		<IconButton icon={space.icon} title="Spaces (⌘K)" onclick={() => shell.toggleSpaces()} />
		<IconButton icon="plus" tone="accent" title="New session" onclick={() => shell.openNewSession()} />
		<div class="my-0.5 h-px w-5" style:background="var(--border)"></div>
		{#each DOCK_SOURCES as s (s.id)}
			<IconButton
				icon={s.icon}
				title={s.label}
				onclick={() => {
					collapsed = false;
					openSections[s.id] = true;
				}}
			/>
		{/each}
	</div>
{:else}
	<div class="flex w-[210px] shrink-0 flex-col border-r border-hair bg-shell">
		<!-- top line — ONE row. Desktop: just clear the OS traffic-light strip (no logo,
		     no collapse — a narrow rail would clip the lights). Web: brand + collapse. -->
		{#if isTauri}
			<div class="h-[42px] shrink-0" data-tauri-drag-region></div>
		{:else}
			<div class="flex h-[44px] shrink-0 items-center gap-2 px-2.5">
				<span
					class="grid size-[20px] shrink-0 place-items-center rounded-[6px] bg-brand text-ui font-semibold leading-none ring-1 ring-[var(--border-strong)]"
					style:color="var(--accent-contrast)"
					aria-hidden="true">L</span>
				<span class="text-title font-semibold tracking-tight text-ink-1">Legend</span>
				<div class="flex-1"></div>
				<IconButton icon="panel-right" title="Collapse dock" onclick={() => (collapsed = true)} />
			</div>
		{/if}

		<!-- spaces switcher + New session -->
		<div class="flex shrink-0 flex-col gap-2 border-b border-hair px-2.5 pb-2.5 pt-1">
			<!-- Spaces switcher: shows the active space; ⌘K toggles the overlay -->
			<button
				type="button"
				onclick={() => shell.toggleSpaces()}
				aria-expanded={shell.spacesOpen}
				class="flex h-[30px] w-full items-center gap-2 rounded-md border border-hair-strong bg-raised pl-2.5 pr-2 transition-colors hover:border-[color-mix(in_oklab,var(--accent-hi)_30%,var(--border-strong))]"
			>
				<Icon name={space.icon} size={15} class="shrink-0 text-brand-hi" />
				<span class="min-w-0 flex-1 truncate text-left text-title font-semibold text-ink-1">{space.name}</span>
				{#if count !== undefined}
					<span class="shrink-0 font-mono text-ui text-ink-3">{count}</span>
				{/if}
				<Icon name="chevron-down" size={14} class="shrink-0 text-ink-3" />
			</button>

			<Button size="sm" class="h-[30px] w-full" onclick={() => shell.openNewSession()}>New session</Button>
		</div>

		<!-- pluggable source sections -->
		<div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
			{#each DOCK_SOURCES as s (s.id)}
				{@const Section = s.component}
				<div
					class="flex min-h-0 flex-col border-b border-hair last:border-b-0"
					class:flex-1={openSections[s.id]}
				>
					<Section
						open={openSections[s.id]}
						ontoggle={() => (openSections[s.id] = !openSections[s.id])}
					/>
				</div>
			{/each}
		</div>
	</div>
{/if}
