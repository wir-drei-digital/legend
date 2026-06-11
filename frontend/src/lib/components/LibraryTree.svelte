<script lang="ts">
	import type { TreeNode } from '$lib/library';

	let {
		nodes,
		selected,
		onselect
	}: {
		nodes: TreeNode[];
		selected: string | null;
		onselect: (path: string) => void;
	} = $props();

	let collapsed = $state<Record<string, boolean>>({});
</script>

{#snippet node(n: TreeNode, depth: number)}
	<div style={`padding-left: ${depth * 0.75}rem`}>
		{#if n.type === 'dir'}
			<button
				class="flex w-full items-center gap-1 rounded px-1 py-0.5 text-sm hover:bg-accent"
				onclick={() => (collapsed[n.path] = !collapsed[n.path])}
			>
				<span class="text-muted-foreground">{collapsed[n.path] ? '▸' : '▾'}</span>
				<span class="truncate">{n.name}/</span>
			</button>
			{#if !collapsed[n.path]}
				{#each n.children as child (child.path)}
					{@render node(child, depth + 1)}
				{/each}
			{/if}
		{:else}
			<button
				class="block w-full truncate rounded px-1 py-0.5 text-left text-sm hover:bg-accent
					{selected === n.path ? 'bg-accent' : ''}"
				onclick={() => onselect(n.path)}
			>
				{n.name}
			</button>
		{/if}
	</div>
{/snippet}

{#each nodes as n (n.path)}
	{@render node(n, 0)}
{/each}
