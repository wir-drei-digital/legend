<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import { Button } from '$lib/components/ui/button';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { relativeTime, formatBytes } from '$lib/shell/format';
	import { filesStore } from '$lib/stores/files.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { deleteFile } from '$lib/library';

	// `params` is part of the uniform surface contract; FileSurface reads its path
	// via workspaceStore.tilePath(tileId) instead, so it stays unused for now.
	let {
		tileId,
		grab,
		params
	}: { tileId: string; grab?: (e: PointerEvent) => void; params?: Record<string, unknown> } = $props();

	const layout = $derived(workspaceStore.active.layout);
	const path = $derived(workspaceStore.tilePath(tileId));
	const active = $derived(layout.activeId === tileId);
	const focusedMode = $derived(layout.focusedId === tileId);
	const dragging = $derived(layout.draggingId === tileId);
	const buf = $derived(path ? filesStore.buffer(path) : undefined);
	const dirty = $derived(path ? filesStore.dirty(path) : false);
	const crumbs = $derived(path ? path.split('/') : []);

	let menuOpen = $state(false);
	let detailsOpen = $state(false);

	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}

	async function confirmDelete() {
		menuOpen = false;
		if (!path) return;
		try {
			await deleteFile(path);
			filesStore.release(path);
			workspaceStore.closeTile(tileId);
			await libraryStore.refresh();
		} catch (e) {
			libraryStore.error = e instanceof Error ? e.message : 'failed to delete';
		}
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => layout.setActive(tileId)}
>
	<!-- header -->
	<div
		class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-2.5"
		style:background={active
			? 'color-mix(in oklab, var(--accent) 7%, var(--bg-shell))'
			: 'var(--bg-shell)'}
	>
		<div
			class="flex min-w-0 flex-1 items-center gap-1 {dragging ? 'cursor-grabbing' : 'cursor-grab'}"
			onpointerdown={(e) => grab?.(e)}
			role="button"
			tabindex="-1"
			title="Drag to re-tile"
		>
			{#if path}
				<span class="shrink-0 text-meta text-ink-3">Library</span>
				{#each crumbs as c, i (i)}
					<Icon name="chevron-right" size={11} class="shrink-0 text-ink-3" />
					<span class="truncate text-ui {i === crumbs.length - 1 ? 'font-semibold text-ink-1' : 'text-ink-3'}">{c}</span>
				{/each}
			{:else}
				<span class="text-ui text-ink-3">Select a file</span>
			{/if}
		</div>

		{#if dirty}<span class="shrink-0 text-meta text-warn">Unsaved</span>{/if}

		<Button size="sm" class="h-7 px-2.5 text-meta" onclick={() => path && filesStore.save(path)} disabled={!dirty}>Save</Button>
		<IconButton icon="columns" size={14} box={20} title="Split right" onclick={() => workspaceStore.splitActive()} />
		<IconButton icon="eye" size={14} box={20} title={focusedMode ? 'Restore grid' : 'Focus pane'} active={focusedMode} tone="accent" onclick={toggleFocus} />
		<IconButton icon="panel-right" size={14} box={20} title="Details" active={detailsOpen} tone="accent" onclick={() => (detailsOpen = !detailsOpen)} />
		<div class="relative shrink-0">
			<IconButton icon="more" size={14} box={20} title="More actions" active={menuOpen} onclick={() => (menuOpen = !menuOpen)} />
			<Popover bind:open={menuOpen} class="right-0 top-[26px] w-[160px]">
				{#if path}
					<ConfirmButton idleLabel="Delete file" confirmLabel="Confirm delete" onconfirm={confirmDelete} />
				{:else}
					<p class="px-2.5 py-1.5 text-meta text-ink-3">No file selected.</p>
				{/if}
			</Popover>
		</div>
		<IconButton icon="close" size={14} box={20} title="Close pane" onclick={() => workspaceStore.closeTile(tileId)} />
	</div>

	<!-- body -->
	<div class="flex min-h-0 flex-1">
		<div class="relative min-w-0 flex-1 overflow-hidden">
			{#if path && buf}
				<textarea
					value={buf.content}
					oninput={(e) => filesStore.setContent(path, e.currentTarget.value)}
					onkeydown={(e) => {
						if ((e.metaKey || e.ctrlKey) && e.key === 's') {
							e.preventDefault();
							void filesStore.save(path);
						}
					}}
					class="h-full w-full resize-none bg-app p-3.5 font-mono text-body leading-relaxed text-ink-1 outline-none"
					spellcheck="false"
				></textarea>
			{:else}
				<div class="flex h-full items-center justify-center">
					<p class="text-body text-ink-3">Select a file from the tree, or create one.</p>
				</div>
			{/if}
		</div>

		{#if detailsOpen && path}
			{@const e = libraryStore.entries.find((x) => x.path === path)}
			<div class="w-[260px] shrink-0 border-l border-hair">
				<SidePane title="Details" icon="file" onClose={() => (detailsOpen = false)}>
					{#if e}
						<SidePaneSection label="File">
							<SidePaneField label="Type" value={e.type === 'dir' ? 'Folder' : 'Document'} />
							<SidePaneField label="Size" value={formatBytes(e.size)} />
							<SidePaneField label="Modified" value={relativeTime(e.mtime) || '—'} />
							<SidePaneField label="Path" value={e.path} />
						</SidePaneSection>
					{/if}
					{#snippet footer()}
						<Button
							size="sm"
							variant="outline"
							class="h-8 w-full text-meta"
							onclick={() => navigator.clipboard?.writeText(path)}
						>
							<Icon name="link" size={13} class="mr-1.5" /> Copy reference
						</Button>
					{/snippet}
				</SidePane>
			</div>
		{/if}
	</div>
</div>
