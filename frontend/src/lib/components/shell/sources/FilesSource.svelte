<script lang="ts">
	import { onMount } from 'svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import { Button } from '$lib/components/ui/button';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { filesStore } from '$lib/stores/files.svelte';
	import { dockDrag } from '$lib/shell/dock-drag.svelte';
	import { filterTree, writeFile } from '$lib/library';

	let searching = $state(false);
	let query = $state('');
	const filtered = $derived(query.trim() ? filterTree(libraryStore.tree, query) : libraryStore.tree);
	const fileCount = $derived(libraryStore.entries.filter((e) => e.type === 'file').length);

	// The first open dirty path drives the dirty dot; the active tile drives selection.
	const dirtyPath = $derived(filesStore.openPaths().find((p) => filesStore.dirty(p)) ?? null);

	// New-file popover: create an empty file, refresh the tree, open it as a tile.
	let newOpen = $state(false);
	let newPath = $state('');
	async function createFile() {
		const p = newPath.trim();
		if (!p) return;
		await writeFile(p, '');
		await libraryStore.refresh();
		workspaceStore.openSurface('file', { path: p });
		newPath = '';
		newOpen = false;
	}

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
		<div class="relative shrink-0">
			<IconButton
				icon="plus"
				size={13}
				title="New file"
				active={newOpen}
				onclick={() => (newOpen = !newOpen)}
			/>
			<Popover bind:open={newOpen} class="right-0 top-[30px] w-[280px]">
				<div class="p-2.5">
					<SectionLabel class="mb-1.5 block"><label for="rail-new-file-path">New file path</label></SectionLabel>
					<!-- svelte-ignore a11y_autofocus -->
					<input
						id="rail-new-file-path"
						autofocus
						bind:value={newPath}
						placeholder="skills/my-skill.md"
						onkeydown={(e) => {
							if (e.key === 'Enter') {
								e.preventDefault();
								void createFile();
							} else if (e.key === 'Escape') {
								newOpen = false;
							}
						}}
						class="w-full rounded-[7px] border border-hair-strong bg-inset px-2 py-1.5 text-ui text-ink-1 placeholder:text-ink-3 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
					/>
					<div class="mt-2 flex justify-end gap-2">
						<Button
							size="sm"
							variant="outline"
							class="h-7 px-2.5 text-meta"
							onclick={() => (newOpen = false)}
						>
							Cancel
						</Button>
						<Button size="sm" class="h-7 px-2.5 text-meta" onclick={createFile} disabled={!newPath.trim()}>
							Create
						</Button>
					</div>
				</div>
			</Popover>
		</div>
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
			onselect={(p) => workspaceStore.openSurface('file', { path: p })}
			ondragstart={(p, e) =>
				dockDrag.start(e, { kind: 'file', params: { path: p }, label: p.split('/').at(-1) ?? p })}
		/>
	</div>
</div>
