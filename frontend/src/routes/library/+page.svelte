<script lang="ts">
	import { onMount } from 'svelte';
	import WorkbenchLayout from '$lib/components/shell/WorkbenchLayout.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import { Button } from '$lib/components/ui/button';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { filterTree } from '$lib/library';
	import { relativeTime, formatBytes } from '$lib/shell/format';

	let sideOpen = $state(true);
	let sideWidth = $state(320);

	// rail filter
	let searching = $state(false);
	let query = $state('');
	const filtered = $derived(query.trim() ? filterTree(libraryStore.tree, query) : libraryStore.tree);
	const fileCount = $derived(libraryStore.entries.filter((e) => e.type === 'file').length);

	// editor ⋯ menu (ConfirmButton owns the two-step delete)
	let menuOpen = $state(false);

	// Switching files dismisses an open menu (the store can't reach this
	// page-local UI state).
	$effect(() => {
		void libraryStore.selected;
		menuOpen = false;
	});

	const sel = $derived(libraryStore.selected);
	const crumbs = $derived(sel ? sel.split('/') : []);

	function copyReference() {
		if (sel && typeof navigator !== 'undefined') void navigator.clipboard?.writeText(sel);
	}

	async function confirmDelete() {
		await libraryStore.remove();
		menuOpen = false;
	}

	onMount(() => void libraryStore.refresh());
</script>

<WorkbenchLayout storageKey="legend:library:side" bind:sideOpen bind:sideWidth>
	{#snippet rail()}
		<!-- rail header -->
		<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
			{#if searching}
				<!-- svelte-ignore a11y_autofocus -->
				<input
					autofocus
					bind:value={query}
					onblur={() => {
						if (!query) searching = false;
					}}
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
				onclick={() => {
					searching = !searching;
					if (!searching) query = '';
				}}
			/>
		</div>
		<!-- tree -->
		<div class="min-h-0 flex-1 overflow-y-auto py-1.5">
			<LibraryTree
				nodes={filtered}
				selected={libraryStore.selected}
				dirtyPath={libraryStore.dirty ? libraryStore.selected : null}
				onselect={(p) => libraryStore.open(p)}
			/>
		</div>
	{/snippet}

	{#snippet primary()}
		<!-- editor header -->
		<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-3">
			{#if sel}
				<div class="flex min-w-0 flex-1 items-center gap-1 text-ui">
					<span class="shrink-0 text-ink-3">Library</span>
					{#each crumbs as c, i (i)}
						<Icon name="chevron-right" size={11} class="shrink-0 text-ink-3" />
						<span
							class="truncate {i === crumbs.length - 1 ? 'font-semibold text-ink-1' : 'text-ink-3'}"
						>
							{c}
						</span>
					{/each}
				</div>
				{#if libraryStore.dirty}
					<span class="shrink-0 text-meta text-warn">Unsaved</span>
				{/if}
				<Button
					size="sm"
					class="h-7 px-2.5 text-meta"
					onclick={() => libraryStore.save()}
					disabled={!libraryStore.dirty}
				>
					Save
				</Button>
				<IconButton
					icon="panel-right"
					title="Toggle details"
					active={sideOpen}
					tone="accent"
					onclick={() => (sideOpen = !sideOpen)}
				/>
				<div class="relative shrink-0">
					<IconButton
						icon="more"
						title="More actions"
						active={menuOpen}
						onclick={() => (menuOpen = !menuOpen)}
					/>
					<Popover bind:open={menuOpen} class="right-0 top-[30px] w-[160px]">
						<ConfirmButton
							idleLabel="Delete file"
							confirmLabel="Confirm delete"
							onconfirm={confirmDelete}
						/>
					</Popover>
				</div>
			{:else}
				<span class="text-ui text-ink-3">Select a file</span>
			{/if}
		</div>

		{#if libraryStore.error}
			<div class="shrink-0 border-b border-hair px-3 py-1.5 text-meta" style:color="var(--red)">
				{libraryStore.error}
			</div>
		{/if}

		<!-- editor body -->
		{#if sel}
			<textarea
				bind:value={libraryStore.content}
				onkeydown={(e) => {
					if ((e.metaKey || e.ctrlKey) && e.key === 's') {
						e.preventDefault();
						void libraryStore.save();
					}
				}}
				class="min-h-0 flex-1 resize-none bg-app p-3.5 font-mono text-body leading-relaxed text-ink-1 outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex flex-1 items-center justify-center">
				<p class="text-body text-ink-3">Select a file from the tree, or create one.</p>
			</div>
		{/if}
	{/snippet}

	{#snippet side()}
		<SidePane title="Details" icon="file" onClose={() => (sideOpen = false)}>
			{#if libraryStore.selectedEntry}
				{@const e = libraryStore.selectedEntry}
				<SidePaneSection label="File">
					<div class="flex items-center gap-2.5">
						<span
							class="grid size-9 shrink-0 place-items-center rounded-[9px] border border-hair bg-inset text-ink-2"
						>
							<Icon name="file" size={18} />
						</span>
						<div class="min-w-0">
							<p class="truncate text-body font-semibold text-ink-1">
								{e.path.split('/').at(-1)}
							</p>
							<p class="text-meta text-ink-3">
								{e.type === 'dir' ? 'Folder' : 'Document'} · {formatBytes(e.size)}
							</p>
						</div>
					</div>
				</SidePaneSection>
				<SidePaneSection label="Details">
					<SidePaneField label="Modified" value={relativeTime(e.mtime) || '—'} />
					<SidePaneField label="Path" value={e.path} />
				</SidePaneSection>
			{:else}
				<p class="text-ui text-ink-3">No file selected.</p>
			{/if}

			{#snippet footer()}
				<Button
					size="sm"
					variant="outline"
					class="h-8 w-full text-meta"
					disabled={!sel}
					onclick={copyReference}
				>
					<Icon name="link" size={13} class="mr-1.5" />
					Copy reference
				</Button>
			{/snippet}
		</SidePane>
	{/snippet}
</WorkbenchLayout>
