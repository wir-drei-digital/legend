<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import { Button } from '$lib/components/ui/button';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { libraryStore } from '$lib/stores/library.svelte';
	import { relativeTime, formatBytes } from '$lib/shell/format';

	const path = $derived(workspaceStore.activePath);
	const entry = $derived(path ? (libraryStore.entries.find((e) => e.path === path) ?? null) : null);

	function copyReference() {
		if (path && typeof navigator !== 'undefined') void navigator.clipboard?.writeText(path);
	}
</script>

<SidePane title="Details" icon="file">
	{#if entry}
		<SidePaneSection label="File">
			<div class="flex items-center gap-2.5">
				<span class="grid size-9 shrink-0 place-items-center rounded-[9px] border border-hair bg-inset text-ink-2">
					<Icon name="file" size={18} />
				</span>
				<div class="min-w-0">
					<p class="truncate text-body font-semibold text-ink-1">{entry.path.split('/').at(-1)}</p>
					<p class="text-meta text-ink-3">{entry.type === 'dir' ? 'Folder' : 'Document'} · {formatBytes(entry.size)}</p>
				</div>
			</div>
		</SidePaneSection>
		<SidePaneSection label="Details">
			<SidePaneField label="Modified" value={relativeTime(entry.mtime) || '—'} />
			<SidePaneField label="Path" value={entry.path} />
		</SidePaneSection>
	{:else}
		<p class="text-ui text-ink-3">No file selected.</p>
	{/if}

	{#snippet footer()}
		<Button size="sm" variant="outline" class="h-8 w-full text-meta" disabled={!path} onclick={copyReference}>
			<Icon name="link" size={13} class="mr-1.5" />
			Copy reference
		</Button>
	{/snippet}
</SidePane>
