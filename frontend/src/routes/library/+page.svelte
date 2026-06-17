<script lang="ts">
	import { onMount } from 'svelte';
	import WorkbenchLayout from '$lib/components/shell/WorkbenchLayout.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import LibraryTree from '$lib/components/library/LibraryTree.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
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

	// editor ⋯ menu (two-step delete)
	let menuOpen = $state(false);
	let confirmingDelete = $state(false);

	// Switching files dismisses an in-flight delete confirmation / open menu
	// (the store can't reach this page-local UI state).
	$effect(() => {
		void libraryStore.selected;
		menuOpen = false;
		confirmingDelete = false;
	});

	const sel = $derived(libraryStore.selected);
	const crumbs = $derived(sel ? sel.split('/') : []);

	function copyReference() {
		if (sel && typeof navigator !== 'undefined') void navigator.clipboard?.writeText(sel);
	}

	async function confirmDelete() {
		await libraryStore.remove();
		menuOpen = false;
		confirmingDelete = false;
	}

	onMount(() => void libraryStore.refresh());
</script>

<WorkbenchLayout storageKey="legend:library:side" bind:sideOpen bind:sideWidth>
	{#snippet rail()}
		<!-- rail header -->
		<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
			{#if searching}
				<!-- svelte-ignore a11y_autofocus -->
				<input
					autofocus
					bind:value={query}
					onblur={() => {
						if (!query) searching = false;
					}}
					placeholder="Filter…"
					class="min-w-0 flex-1 bg-transparent text-[11.5px] text-ink-1 placeholder:text-ink-3 focus:outline-none"
				/>
			{:else}
				<span class="text-[11.5px] font-semibold text-ink-2">Explorer</span>
				<span class="font-mono text-[10.5px] text-ink-3">{fileCount}</span>
				<div class="flex-1"></div>
			{/if}
			<button
				type="button"
				onclick={() => {
					searching = !searching;
					if (!searching) query = '';
				}}
				class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
				title="Filter library"
			>
				<Icon name={searching ? 'close' : 'search'} size={13} />
			</button>
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
		<div class="flex h-8 shrink-0 items-center gap-2 border-b border-hair px-3">
			{#if sel}
				<div class="flex min-w-0 flex-1 items-center gap-1 text-[11.5px]">
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
					<span class="shrink-0 text-[10.5px] text-warn">Unsaved</span>
				{/if}
				<Button
					size="sm"
					class="h-7 px-2.5 text-[11px]"
					onclick={() => libraryStore.save()}
					disabled={!libraryStore.dirty}
				>
					Save
				</Button>
				<button
					type="button"
					onclick={() => (sideOpen = !sideOpen)}
					title="Toggle details"
					class="grid size-6 shrink-0 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
					class:text-brand-hi={sideOpen}
				>
					<Icon name="panel-right" size={14} />
				</button>
				<div class="relative shrink-0">
					<button
						type="button"
						onclick={() => (menuOpen = !menuOpen)}
						aria-expanded={menuOpen}
						title="More actions"
						class="grid size-6 place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-2"
						class:text-ink-1={menuOpen}
					>
						<Icon name="more" size={14} />
					</button>
					{#if menuOpen}
						<button
							type="button"
							class="fixed inset-0 z-40 cursor-default"
							aria-label="Close menu"
							onclick={() => {
								menuOpen = false;
								confirmingDelete = false;
							}}
						></button>
						<div
							class="absolute right-0 top-[30px] z-50 w-[160px] overflow-hidden rounded-[10px] border border-hair-strong bg-panel py-1 shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)]"
							style:animation="lg-rise 0.12s ease-out"
						>
							{#if confirmingDelete}
								<button
									type="button"
									onclick={confirmDelete}
									class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] font-medium transition-colors hover:bg-[color-mix(in_oklab,var(--red)_16%,transparent)]"
									style:color="var(--red)"
								>
									<Icon name="trash" size={13} />
									Confirm delete
								</button>
							{:else}
								<button
									type="button"
									onclick={() => (confirmingDelete = true)}
									class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] transition-colors hover:bg-[color-mix(in_oklab,var(--red)_12%,transparent)]"
									style:color="var(--red)"
								>
									<Icon name="trash" size={13} />
									Delete file
								</button>
							{/if}
						</div>
					{/if}
				</div>
			{:else}
				<span class="text-[11.5px] text-ink-3">Select a file</span>
			{/if}
		</div>

		{#if libraryStore.error}
			<div class="shrink-0 border-b border-hair px-3 py-1.5 text-[11px]" style:color="var(--red)">
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
				class="min-h-0 flex-1 resize-none bg-app p-3.5 font-mono text-[12px] leading-relaxed text-ink-1 outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex flex-1 items-center justify-center">
				<p class="text-[12px] text-ink-3">Select a file from the tree, or create one.</p>
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
							<p class="truncate text-[12.5px] font-semibold text-ink-1">
								{e.path.split('/').at(-1)}
							</p>
							<p class="text-[11px] text-ink-3">
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
				<p class="text-[11.5px] text-ink-3">No file selected.</p>
			{/if}

			{#snippet footer()}
				<Button
					size="sm"
					variant="outline"
					class="h-8 w-full text-[11px]"
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
