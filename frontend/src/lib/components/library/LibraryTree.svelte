<script lang="ts">
	import type { TreeNode } from '$lib/library';
	import Icon from '$lib/components/shell/Icon.svelte';

	let {
		nodes,
		selected,
		openPaths = [],
		dirtyPath = null,
		onselect,
		ondragstart
	}: {
		nodes: TreeNode[];
		selected: string | null;
		openPaths?: string[];
		dirtyPath?: string | null;
		onselect: (path: string) => void;
		ondragstart?: (path: string, e: PointerEvent) => void;
	} = $props();

	let collapsed = $state<Record<string, boolean>>({});
</script>

{#snippet node(n: TreeNode, depth: number)}
	{#if n.type === 'dir'}
		<button
			type="button"
			class="flex h-[var(--h-row)] w-full items-center gap-1.5 pr-2 text-left text-ui text-ink-2 transition-colors hover:bg-[var(--hover-tint)]"
			style:padding-left="{depth * 12 + 12}px"
			aria-expanded={!collapsed[n.path]}
			onclick={() => (collapsed[n.path] = !collapsed[n.path])}
		>
			<Icon
				name={collapsed[n.path] ? 'chevron-right' : 'chevron-down'}
				size={12}
				class="shrink-0 text-ink-3"
			/>
			<Icon name="folder" size={13} class="shrink-0 text-ink-3" />
			<span class="min-w-0 truncate">{n.name}</span>
		</button>
		{#if !collapsed[n.path]}
			{#each n.children as child (child.path)}
				{@render node(child, depth + 1)}
			{/each}
		{/if}
	{:else}
		{@const active = selected === n.path}
		{@const open = !active && openPaths.includes(n.path)}
		<button
			type="button"
			class="relative flex h-[var(--h-row)] w-full items-center gap-1.5 pr-2 text-left text-ui transition-colors hover:bg-[var(--hover-tint)]"
			style:padding-left="{depth * 12 + 12}px"
			style:background={active ? 'var(--accent-soft)' : undefined}
			style:color={active || open ? 'var(--text-1)' : 'var(--text-2)'}
			onclick={() => onselect(n.path)}
			onpointerdown={(e) => ondragstart?.(n.path, e)}
		>
			<span
				class="absolute left-0 top-0 h-full w-[2px]"
				style:background={active || open ? 'var(--accent)' : 'transparent'}
				style:opacity={open ? 0.55 : 1}
			></span>
			<Icon name="file" size={13} class="shrink-0 text-ink-3" />
			<span class="min-w-0 flex-1 truncate">{n.name}</span>
			{#if dirtyPath === n.path}
				<span
					class="size-1.5 shrink-0 rounded-full"
					style:background="var(--accent)"
					title="Unsaved changes"
				></span>
			{/if}
		</button>
	{/if}
{/snippet}

{#each nodes as n (n.path)}
	{@render node(n, 0)}
{:else}
	<p class="px-3 py-2 text-meta text-ink-3">Empty.</p>
{/each}
