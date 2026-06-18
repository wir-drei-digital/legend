<script lang="ts">
	import { onMount } from 'svelte';
	import Icon from './Icon.svelte';
	import IconButton from './IconButton.svelte';
	import { DOCK_SOURCES } from '$lib/shell/dock-sources';

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

{#if collapsed}
	<div class="flex w-9 shrink-0 flex-col items-center gap-2 border-r border-hair bg-shell pt-2.5">
		<IconButton icon="panel-right" title="Expand dock" onclick={() => (collapsed = false)} />
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
		<div
			class="flex h-[var(--h-bar)] shrink-0 items-center justify-between border-b border-hair pl-3 pr-1.5"
		>
			<span class="text-ui font-semibold text-ink-2">Sources</span>
			<IconButton icon="panel-right" title="Collapse dock" onclick={() => (collapsed = true)} />
		</div>
		<div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
			{#each DOCK_SOURCES as s (s.id)}
				{@const Section = s.component}
				<div
					class="flex min-h-0 flex-col border-b border-hair last:border-b-0"
					class:flex-1={openSections[s.id]}
				>
					<button
						type="button"
						onclick={() => (openSections[s.id] = !openSections[s.id])}
						class="flex h-[var(--h-row)] shrink-0 items-center gap-1.5 px-2.5 text-left"
					>
						<Icon
							name={openSections[s.id] ? 'chevron-down' : 'chevron-right'}
							size={12}
							class="text-ink-3"
						/>
						<Icon name={s.icon} size={13} class="text-ink-3" />
						<span
							class="font-mono text-micro font-semibold uppercase tracking-[0.14em] text-ink-3"
							>{s.label}</span
						>
					</button>
					{#if openSections[s.id]}
						<div class="min-h-0 flex-1 overflow-y-auto"><Section /></div>
					{/if}
				</div>
			{/each}
		</div>
	</div>
{/if}
