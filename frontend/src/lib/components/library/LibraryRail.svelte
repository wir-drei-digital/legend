<script lang="ts">
	import { onMount } from 'svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { filesStore } from '$lib/stores/files.svelte';
	import { filterTree } from '$lib/library';

	let searching = $state(false);
	let query = $state('');
	const filtered = $derived(query.trim() ? filterTree(libraryStore.tree, query) : libraryStore.tree);
	const fileCount = $derived(libraryStore.entries.filter((e) => e.type === 'file').length);

	// The first open dirty path drives the dirty dot; the active tile drives selection.
	const dirtyPath = $derived(filesStore.openPaths().find((p) => filesStore.dirty(p)) ?? null);

	onMount(() => void libraryStore.refresh());
</script>

<div class="flex h-full flex-col">
	<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
		{#if searching}
			<!-- svelte-ignore a11y_autofocus -->
			<input
				autofocus
				bind:value={query}
				onblur={() => { if (!query) searching = false; }}
				placeholder="Filter…"
				class="min-w-0 flex-1 bg-transparent text-ui text-ink-1 placeholder:text-ink-3 focus:outline-none"
			/>
		{:else}
			<span class="text-ui font-semibold text-ink-2">Explorer</span>
			<span class="font-mono text-meta text-ink-3">{fileCount}</span>
			<div class="flex-1"></div>
		{/if}
		<IconButton
			icon={searching ? 'close' : 'search'}
			size={13}
			title="Filter library"
			onclick={() => { searching = !searching; if (!searching) query = ''; }}
		/>
	</div>
	<div class="min-h-0 flex-1 overflow-y-auto py-1.5">
		<LibraryTree
			nodes={filtered}
			selected={workspaceStore.activePath}
			{dirtyPath}
			onselect={(p) => workspaceStore.openFile(p)}
		/>
	</div>
</div>
