<script lang="ts">
	import { workspaceStore } from '$lib/shell/workspace.svelte';
</script>

<div class="flex items-center gap-0.5 rounded-[8px] border border-hair bg-inset p-0.5">
	{#each workspaceStore.spaces as s (s.id)}
		<button
			type="button"
			onclick={() => workspaceStore.switchSpace(s.id)}
			class="rounded-[6px] px-2.5 py-1 text-meta font-medium transition-colors"
			style:background={workspaceStore.activeId === s.id ? 'var(--accent-soft)' : 'transparent'}
			style:color={workspaceStore.activeId === s.id ? 'var(--text-1)' : 'var(--text-3)'}
		>
			{s.name}
		</button>
	{/each}
</div>
