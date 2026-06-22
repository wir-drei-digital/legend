<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import IconButton from './IconButton.svelte';

	// Generic window-pane header. Owns the chrome every surface shares — active
	// tint, the drag-to-retile handle, maximize/restore, and close — and leaves
	// surface identity (`title`), status (`meta`), and extra icon buttons
	// (`actions`) to snippet props. A dumb shell primitive: no store imports.
	let {
		tileId,
		layout,
		grab,
		onClose,
		title,
		meta,
		actions
	}: {
		tileId: string;
		layout: TileLayout;
		grab?: (e: PointerEvent) => void;
		onClose: () => void;
		title: Snippet;
		meta?: Snippet;
		actions?: Snippet;
	} = $props();

	const active = $derived(layout.activeId === tileId);
	const focusedMode = $derived(layout.focusedId === tileId);
	const dragging = $derived(layout.draggingId === tileId);

	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}
</script>

<div
	class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-2.5"
	style:background={active
		? 'color-mix(in oklab, var(--accent) 7%, var(--bg-shell))'
		: 'var(--bg-shell)'}
>
	<!-- drag handle: press + drag a tile by its header to re-tile the grid -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div
		class="flex min-w-0 flex-1 items-center gap-2 {dragging ? 'cursor-grabbing' : 'cursor-grab'}"
		onpointerdown={(e) => grab?.(e)}
		role="button"
		tabindex="-1"
		title="Drag to re-tile"
	>
		{@render title()}
	</div>

	{#if meta}{@render meta()}{/if}

	<!-- actions cluster: surface extras + universal maximize/close as one tight unit -->
	<div class="flex shrink-0 items-center gap-0.5">
		{#if actions}{@render actions()}{/if}
		<IconButton
			icon={focusedMode ? 'shrink' : 'expand'}
			size={14}
			box={24}
			title={focusedMode ? 'Restore grid' : 'Maximize pane'}
			active={focusedMode}
			tone="accent"
			onclick={toggleFocus}
		/>
		<IconButton icon="close" size={14} box={24} title="Close pane" onclick={onClose} />
	</div>
</div>
